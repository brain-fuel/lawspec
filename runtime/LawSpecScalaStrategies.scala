package lawspec.testing

import java.util.{Map => JMap}
import scala.collection.mutable
import scala.jdk.CollectionConverters.*
import lawspec.runtime.LawSpecRuntime.{Data, Presence, Value}
import lawspec.runtime.LawSpecSchema
import lawspec.runtime.LawSpecSchema.Named

/** Generation and shrinking for instantiated Core data schemas, on LawSpec's
  * shrink trees.
  *
  * Generated tests run on ScalaCheck, so failures shrink and report as Scala
  * developers expect; every candidate is built from the schema's own
  * constructors, so shrinking stays within the declared domain.
  * ref:DEC-native-property-frameworks ref:scalacheck
  * ref:DEC-shrink-within-domain
  */
object LawSpecScalaStrategies:
  def generator(
      schema: LawSpecSchema,
      tpe: Named,
      bits: Int,
      budget: Int,
      scalar: String => Arb[Value]
  ): Arb[Value] =
    require(
      !schema.hasContracts(),
      "constructor contracts require checked generation"
    )
    require(budget > 0, "structural node budget must be positive")
    require(bits == 32 || bits == 64, "machineBits must be 32 or 64")
    schema.isScalar(
      tpe
    ) // Validate the entire type application before planning.
    Builder(schema, bits, scalar)
      .build(tpe, budget)
      .getOrElse(
        throw IllegalArgumentException(
          s"no value of ${LawSpecSchema.key(tpe)} within structural node budget $budget"
        )
      )

  /** A property's inputs so far, with their symbols, or the error that ended
    * their generation.
    */
  final case class Case(
      values: List[Value],
      symbols: JMap[String, Object],
      error: RuntimeException = null
  ):
    def requireValues(): List[Value] =
      if error != null then throw error
      values

  def cases(): Arb[Case] = _ =>
    Tree.leaf(Case(Nil, java.util.HashMap[String, Object]()))

  def filterCases(source: Arb[Case], attempts: Int)(
      predicate: Case => Boolean
  ): Arb[Case] =
    require(attempts > 0, "maxAttempts must be positive")
    Arb.bounded(source, attempts, "property inputs")(c =>
      c.error != null || predicate(c)
    )

  /** A checked value, or the error that rejected it. */
  final case class Checked(value: Value, error: RuntimeException):
    def requireValue(): Value =
      if error != null then throw error
      value

  /** A bound native generator: the Arb of a type's values, given its
    * arguments'.
    */
  trait NativeFactory:
    def create(
        schema: LawSpecSchema,
        tpe: Named,
        bits: Int,
        symbols: JMap[String, Object],
        arguments: List[Arb[Value]]
    ): Arb[Value]

  private final class NativeFailure(tpe: Named, cause: RuntimeException)
      extends IllegalArgumentException(
        s"native generator ${LawSpecSchema.key(tpe)}: ${cause.getMessage}",
        cause
      )

  def nativeValues[T](
      codec: LawSpecSchema.Codec[T],
      source: Arb[T]
  ): Arb[Value] =
    source.map(value =>
      try codec.encode(value)
      catch
        case error: RuntimeException =>
          throw NativeFailure(codec.`type`(), error)
    )

  def nativeArguments[T](
      codec: LawSpecSchema.Codec[T],
      source: Arb[Value]
  ): Arb[T] =
    source.map(value =>
      try codec.decode(value)
      catch
        case error: RuntimeException =>
          throw NativeFailure(codec.`type`(), error)
    )

  // Retain the tree, including failures met while evaluating a shrink node or
  // enumerating its children. Property callbacks report those.
  private def capture(source: Arb[Checked]): Arb[Checked] =
    def failure(error: NativeFailure): Tree[Checked] =
      Tree.leaf(Checked(null, error))
    def tree(source: Tree[Checked]): Tree[Checked] =
      Tree(
        source.value,
        try source.children.map(tree).toList.to(LazyList)
        catch case error: NativeFailure => LazyList(failure(error))
      )
    rng =>
      try tree(source.sample(rng))
      catch case error: NativeFailure => failure(error)

  def checkedGenerator(
      schema: LawSpecSchema,
      tpe: Named,
      bits: Int,
      budget: Int,
      maxAttempts: Int,
      symbols: JMap[String, Object],
      witnesses: List[Value],
      factories: Map[String, NativeFactory],
      scalar: String => Arb[Value]
  ): Arb[Checked] =
    require(budget > 0, "structural node budget must be positive")
    require(bits == 32 || bits == 64, "machineBits must be 32 or 64")
    require(maxAttempts > 0, "maxAttempts must be positive")
    schema.isScalar(tpe)
    val builder = Builder(schema, bits, scalar, symbols, maxAttempts, factories)
    witnesses.foreach(w =>
      builder.addWitness(tpe, schema.validate(tpe, w, bits, symbols))
    )
    val source = builder
      .build(tpe, budget)
      .getOrElse(
        throw IllegalArgumentException(
          s"no value of ${LawSpecSchema.key(tpe)} within structural node budget $budget"
        )
      )
    capture(
      source.map(value =>
        try Checked(schema.validate(tpe, value, bits, symbols), null)
        catch case error: RuntimeException => Checked(null, error)
      )
    )

  def checkedGenerator(
      schema: LawSpecSchema,
      tpe: Named,
      bits: Int,
      budget: Int,
      maxAttempts: Int,
      symbols: JMap[String, Object],
      witnesses: List[Value],
      scalar: String => Arb[Value]
  ): Arb[Checked] = checkedGenerator(
    schema,
    tpe,
    bits,
    budget,
    maxAttempts,
    symbols,
    witnesses,
    Map.empty,
    scalar
  )

  private def nodes(value: Value): Int = 1 + (value.data() match
    case data: Data     => data.fields().asScala.map(nodes).sum
    case data: Presence => if data.present() then nodes(data.value()) else 0
    case data: java.util.List[?] if value.`type`().startsWith("List ") =>
      data.asScala.map(v => nodes(v.asInstanceOf[Value])).sum
    case _ => 0)

  private val IndexSlack = 16L
  private val IndexChoices = 6

  /** Values whose structural index equals target. Each constructor carries its
    * index term then its guards, in prefix notation over field indices (f<i>),
    * literals (c<n>) and the natural operators. Reachability is a forward
    * fixpoint over levels 0..target+slack, so a child may exceed its parent's
    * index; the target is then solved backwards, and nothing is filtered away.
    */
  def indexedGenerator(
      schema: LawSpecSchema,
      tpe: Named,
      bits: Int,
      budget: Int,
      symbols: JMap[String, Object],
      target: Any,
      equations: Map[String, List[String]],
      scalar: String => Arb[Value]
  ): Arb[Checked] =
    val k = target match
      case value: Value   => value.data().asInstanceOf[Number].longValue()
      case number: Number => number.longValue()
      case number: Int    => number.toLong
      case number: Long   => number
      case _              =>
        throw IllegalArgumentException("index target must be a natural number")
    require(!schema.isScalar(tpe), "indexed generation requires a data type")
    val limit = math.max(k, 0L) + IndexSlack
    val indexed = Indexed(
      schema,
      bits,
      budget,
      limit,
      equations,
      Builder(schema, bits, scalar)
    )
    indexed.explore(tpe)
    // An open target (negative), or one drawn from earlier inputs that breaks their
    // preconditions or names no value, generates from the smallest reachable indices; an index
    // claim rejects a mismatch.
    val levels =
      if indexed.reach.contains((tpe, k)) then List(k)
      else
        (0L to limit)
          .filter(level => indexed.reach.contains((tpe, level)))
          .take(IndexChoices)
          .toList
    require(
      levels.nonEmpty,
      s"no value of ${LawSpecSchema.key(tpe)} has an index"
    )
    val source =
      if levels.size == 1 then indexed.generate(tpe, levels.head)
      else
        Arb.flatMap(Arb.int(0 to levels.size - 1))(i =>
          indexed.generate(tpe, levels(i))
        )
    capture(
      source.map(value =>
        try Checked(schema.validate(tpe, value, bits, symbols), null)
        catch case error: RuntimeException => Checked(null, error)
      )
    )

  /** A prefix index term: kind is "c", "f" or an operator. */
  private final class IndexTerm(
      val kind: String,
      val value: Long,
      val left: IndexTerm,
      val right: IndexTerm
  ):
    /** Natural index arithmetic; None when an operation has no natural value.
      */
    def evaluate(fields: Map[Int, Long]): Option[Long] =
      if kind == "c" then Some(value)
      else if kind == "f" then fields.get(value.toInt)
      else
        for
          x <- left.evaluate(fields)
          y <- right.evaluate(fields)
          a = BigInt(x)
          b = BigInt(y)
          result <- kind match
            case "+"   => Some(a + b)
            case "-"   => if x >= y then Some(a - b) else None
            case "*"   => Some(a * b)
            case "div" => if y > 0 then Some(a / b) else None
            case "mod" => if y > 0 then Some(a.mod(b)) else None
            case _     => if y <= 64 then Some(a.pow(y.toInt)) else None
          if result.bitLength <= 63
        yield result.toLong

    def fields(into: mutable.ArrayBuffer[Int]): Unit =
      if kind == "f" then
        if !into.contains(value.toInt) then into += value.toInt
      else if left != null then
        left.fields(into)
        right.fields(into)

  private object IndexTerm:
    private val Operators = List("+", "-", "*", "div", "mod", "^")

    def parse(tokens: IndexedSeq[String], at: Array[Int]): IndexTerm =
      require(at(0) < tokens.size, "malformed index term")
      val token = tokens(at(0))
      at(0) += 1
      if token.startsWith("c") || token.startsWith("f") then
        IndexTerm(token.substring(0, 1), token.substring(1).toLong, null, null)
      else
        require(Operators.contains(token), "malformed index term")
        val left = parse(tokens, at)
        val right = parse(tokens, at)
        IndexTerm(token, 0, left, right)

  private final class IndexGuard(
      relation: String,
      left: IndexTerm,
      right: IndexTerm
  ):
    def holds(fields: Map[Int, Long]): Boolean =
      (left.evaluate(fields), right.evaluate(fields)) match
        case (Some(x), Some(y)) => if relation == "==" then x == y else x >= y
        case _                  => false

  private final class IndexEquation(
      val term: IndexTerm,
      val guards: List[IndexGuard],
      val positions: List[Int]
  )

  private final class Indexed(
      schema: LawSpecSchema,
      bits: Int,
      budget: Int,
      limit: Long,
      equations: Map[String, List[String]],
      builder: Builder
  ):
    val parsed = mutable.Map[String, IndexEquation]()
    val families = mutable.ArrayBuffer[Named]()
    val reach = mutable.Set[(Named, Long)]()
    val solutions = mutable.Map[(Named, String, Long), List[Map[Int, Long]]]()
    val cache = mutable.Map[(Named, Long), Arb[Value]]()

    def equation(tag: String): IndexEquation = parsed.getOrElseUpdate(
      tag, {
        val texts = equations.getOrElse(
          tag,
          throw IllegalArgumentException(s"missing index equation for $tag")
        )
        require(texts.nonEmpty, s"missing index equation for $tag")
        val tokens = texts.head.split(" ").toIndexedSeq
        val at = Array(0)
        val term = IndexTerm.parse(tokens, at)
        require(at(0) == tokens.size, "malformed index term")
        val positions = mutable.ArrayBuffer[Int]()
        term.fields(positions)
        val guards = texts.tail.map { text =>
          val parts = text.split(" ").toIndexedSeq
          require(parts(0) == "==" || parts(0) == ">=", "malformed index guard")
          val position = Array(1)
          val left = IndexTerm.parse(parts, position)
          val right = IndexTerm.parse(parts, position)
          left.fields(positions)
          right.fields(positions)
          IndexGuard(parts(0), left, right)
        }
        IndexEquation(term, guards, positions.toList)
      }
    )

    def plainFields(tpe: Named, tag: String): Boolean =
      val fields = schema.fields(tpe, tag).asScala
      val positions = equation(tag).positions
      fields.indices.forall(i =>
        positions.contains(i) || builder
          .build(fields(i).`type`().asInstanceOf[Named], budget)
          .isDefined
      )

    // Every guard-satisfying assignment of reachable indices to the index fields.
    def assignments(tpe: Named, tag: String): List[(Long, Map[Int, Long])] =
      val found = equation(tag)
      val fields = schema.fields(tpe, tag).asScala
      val results = mutable.ArrayBuffer[(Long, Map[Int, Long])]()
      def extend(at: Int, current: Map[Int, Long]): Unit =
        if at == found.positions.size then
          if found.guards.forall(_.holds(current)) then
            found.term
              .evaluate(current)
              .foreach(value =>
                if value <= limit then results += ((value, current))
              )
        else
          val position = found.positions(at)
          val fieldType = fields(position).`type`().asInstanceOf[Named]
          for value <- 0L to limit if reach.contains((fieldType, value)) do
            extend(at + 1, current.updated(position, value))
      extend(0, Map.empty)
      results.toList

    def explore(root: Named): Unit =
      val pending = mutable.Stack(root)
      while pending.nonEmpty do
        val tpe = pending.pop()
        if !families.contains(tpe) then
          families += tpe
          for tag <- schema.constructors(tpe).asScala do
            val fields = schema.fields(tpe, tag).asScala
            equation(tag).positions.foreach(i =>
              pending.push(fields(i).`type`().asInstanceOf[Named])
            )
      var grown = true
      while grown do
        val next = mutable.Set[(Named, Long)]()
        for
          tpe <- families
          tag <- schema.constructors(tpe).asScala
          if plainFields(tpe, tag)
          (value, _) <- assignments(tpe, tag)
        do next += ((tpe, value))
        val before = reach.size
        reach ++= next
        grown = reach.size != before

    def solve(tpe: Named, tag: String, k: Long): List[Map[Int, Long]] =
      solutions.getOrElseUpdate(
        (tpe, tag, k),
        assignments(tpe, tag).filter(_._1 == k).map(_._2)
      )

    // Assignments are chosen by index, which shrinks toward the first.
    def generate(tpe: Named, k: Long): Arb[Value] =
      cache.getOrElse(
        (tpe, k), {
          val variants = schema
            .constructors(tpe)
            .asScala
            .toList
            .filter(tag => plainFields(tpe, tag) && solve(tpe, tag, k).nonEmpty)
            .map { tag =>
              val fields = schema.fields(tpe, tag).asScala.toList
              val choices = solve(tpe, tag, k)
              Arb.flatMap(Arb.int(0 to choices.size - 1)) { choice =>
                val targets = choices(choice)
                val children = fields.zipWithIndex.map { (field, index) =>
                  targets.get(index) match
                    case Some(target) =>
                      generate(field.`type`().asInstanceOf[Named], target)
                    case None =>
                      builder
                        .build(field.`type`().asInstanceOf[Named], budget)
                        .get
                }
                children
                  .foldLeft(Arb.constant(List.empty[Value]))((prior, child) =>
                    Arb.bind(prior, child)(_ :+ _)
                  )
                  .map(values =>
                    schema.construct(tpe, tag, values.asJava, bits)
                  )
              }
            }
          require(
            variants.nonEmpty,
            s"no value of ${LawSpecSchema.key(tpe)} has index $k"
          )
          val result = if variants.size == 1 then variants.head
          else Arb.flatMap(Arb.int(0 to variants.size - 1))(variants)
          cache((tpe, k)) = result
          result
        }
      )

  private final case class Request(tpe: Named, budget: Int)

  private final class Builder(
      schema: LawSpecSchema,
      bits: Int,
      scalar: String => Arb[Value],
      symbols: JMap[String, Object] = null,
      maxAttempts: Int = 100,
      factories: Map[String, NativeFactory] = Map.empty
  ):
    val witnesses = mutable.Map[Named, mutable.ArrayBuffer[Value]]()
    val cache = mutable.Map[Request, Option[Arb[Value]]]()

    def addWitness(tpe: Named, value: Value): Unit =
      witnesses.getOrElseUpdate(tpe, mutable.ArrayBuffer()) += value
      if schema.isScalar(tpe) then ()
      else if tpe.name() == "List" then
        value
          .data()
          .asInstanceOf[java.util.List[?]]
          .asScala
          .foreach(item =>
            addWitness(
              tpe.arguments().get(0).asInstanceOf[Named],
              item.asInstanceOf[Value]
            )
          )
      else if tpe.name() == "Nullable" || tpe.name() == "Optional" then
        val presence = value.data().asInstanceOf[Presence]
        if presence.present() then
          addWitness(
            tpe.arguments().get(0).asInstanceOf[Named],
            presence.value()
          )
      else
        val data = value.data().asInstanceOf[Data]
        schema
          .fieldsOf(tpe, data.tag(), data.fields())
          .asScala
          .zipWithIndex
          .foreach((field, index) =>
            addWitness(
              field.`type`().asInstanceOf[Named],
              data.fields().get(index)
            )
          )

    def minimum(tpe: Named, limit: Int): Option[Int] =
      (1 to limit).find(n => build(tpe, n).isDefined)

    def allocation(
        fields: List[LawSpecSchema.Field],
        available: Int
    ): Option[List[Int]] =
      var remaining = available
      val minima = fields.map { field =>
        minimum(field.`type`().asInstanceOf[Named], remaining).map { cost =>
          remaining -= cost
          cost
        }
      }
      if minima.contains(None) then None
      else
        val costs = minima.flatten
        Some(
          costs.zipWithIndex.map((cost, index) =>
            cost + remaining / costs.size + (if index < remaining % costs.size
                                             then 1
                                             else 0)
          )
        )

    def build(tpe: Named, available: Int): Option[Arb[Value]] =
      if available < 1 then return None
      val request = Request(tpe, available)
      cache.get(request) match
        case Some(known) => return known
        case None        => ()
      factories.get(tpe.name()) match
        case Some(factory) =>
          val arguments = tpe.arguments().asScala.toList.map { argument =>
            build(argument.asInstanceOf[Named], available).getOrElse(
              Arb[Value](_ =>
                // A phantom parameter can be uninhabited. Fail only if its
                // factory actually asks this generator for a value.
                throw IllegalStateException(
                  s"no native generator argument for ${LawSpecSchema.key(argument)} within node budget $available"
                )
              )
            )
          }
          val context = symbols
          require(context != null, "native generators need the case's symbols")
          val result = factory
            .create(schema, tpe, bits, context, arguments)
            .map(value =>
              try schema.validate(tpe, value, bits, context)
              catch
                case error: RuntimeException => throw NativeFailure(tpe, error)
            )
          cache(request) = Some(result)
          return Some(result)
        case None => ()
      var result: Option[Arb[Value]] =
        if schema.isScalar(tpe) then
          Some(
            scalar(tpe.name()).map(value => schema.validate(tpe, value, bits))
          )
        else if tpe.name() == "List" then Some(list(tpe, available))
        else if tpe.name() == "Nullable" || tpe.name() == "Optional" then
          Some(presence(tpe, available))
        else
          // A field-only existential takes each type of the witness pool.
          choice(schema.constructors(tpe).asScala.toList.flatMap { tag =>
            schema.instances(tpe, tag).asScala.toList.flatMap { instance =>
              val fields = instance.fields().asScala.toList
              val witnessValues =
                instance.keys().asScala.toList.map(LawSpecSchema.witnessText)
              allocation(fields, available - 1).map { costs =>
                val children = fields.zip(costs).map { (field, cost) =>
                  val fieldType = field.`type`().asInstanceOf[Named]
                  val child = build(fieldType, cost).get
                  // Retain small sets as growing raw lists saturate finite domains.
                  if tpe
                      .name() == "lawspec.collections::type::EqSet" && cost > 3
                  then Arb.choice(build(fieldType, 3).get, child)
                  else child
                }
                val product = children.foldLeft(
                  Arb.constant(List.empty[Value])
                )((prior, child) => Arb.bind(prior, child)(_ :+ _))
                product.map(_ ++ witnessValues).map { values =>
                  val value =
                    if symbols == null && tpe
                        .name() != "lawspec.collections::type::EqSet"
                    then schema.construct(tpe, tag, values.asJava, bits)
                    else Value(LawSpecSchema.key(tpe), Data(tag, values.asJava))
                  // Generated collections are canonicalised rather than filtered.
                  if LawSpecSchema.canonicalCollection(tpe.name()) then
                    LawSpecSchema.canonical(value)
                  else value
                }
              }
            }
          })
      if result.isDefined && symbols != null then
        val seeds = witnesses
          .getOrElse(tpe, mutable.ArrayBuffer())
          .filter(nodes(_) <= available)
          .toVector
        if seeds.nonEmpty then
          result = Some(
            Arb.choice(result.get, Arb.int(0 to seeds.size - 1).map(seeds))
          )
        result = Some(
          Arb.bounded(result.get, maxAttempts, LawSpecSchema.key(tpe))(value =>
            try
              schema
                .check(tpe, value, bits, symbols)
                .isInstanceOf[LawSpecSchema.Accepted]
            catch
              // Keep evaluator errors for the outer checked result to report.
              case _: RuntimeException => true
          )
        )
      cache(request) = result
      result

    def list(tpe: Named, available: Int): Arb[Value] =
      val element = tpe.arguments().get(0).asInstanceOf[Named]
      val remaining = available - 1
      val maximum = minimum(element, remaining).map(remaining / _).getOrElse(0)
      // Plan before sampling: callbacks only select immutable generators.
      val sizes = (0 to maximum).map { length =>
        if length == 0 then
          Arb.constant(Value(LawSpecSchema.key(tpe), java.util.List.of()))
        else
          Arb
            .list(build(element, remaining / length).get, length to length)
            .map(values => Value(LawSpecSchema.key(tpe), values.asJava))
      }
      Arb.flatMap(Arb.int(0 to maximum))(sizes)

    def presence(tpe: Named, available: Int): Arb[Value] =
      val absent =
        Arb.constant(Value(LawSpecSchema.key(tpe), Presence(false, null)))
      build(tpe.arguments().get(0).asInstanceOf[Named], available - 1) match
        case None        => absent
        case Some(child) =>
          choice(
            List(
              absent,
              child.map(v => Value(LawSpecSchema.key(tpe), Presence(true, v)))
            )
          ).get

    def choice(alternatives: List[Arb[Value]]): Option[Arb[Value]] =
      alternatives match
        case Nil         => None
        case only :: Nil => Some(only)
        case _           =>
          Some(Arb.flatMap(Arb.int(0 to alternatives.size - 1))(alternatives))
