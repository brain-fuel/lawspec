package lawspec.testing

import org.scalacheck.{Gen, Prop, Shrink, Test}
import org.scalacheck.util.Pretty
import org.scalacheck.rng.Seed

/** A value and, lazily, the smaller values it may shrink to. */
final class Tree[+A](val value: A, children0: => LazyList[Tree[A]]):
  lazy val children: LazyList[Tree[A]] = children0

  def map[B](f: A => B): Tree[B] = Tree(f(value), children.map(_.map(f)))

  /** The tree without the values the predicate rejects; None when the root is
    * rejected.
    */
  def filter(accepted: A => Boolean): Option[Tree[A]] =
    if !accepted(value) then None
    else Some(Tree(value, children.flatMap(_.filter(accepted))))

object Tree:
  def leaf[A](value: A): Tree[A] = Tree(value, LazyList.empty)

/** The random source a generator draws from: ScalaCheck's own seed, stepped as
  * each choice is drawn, so every random choice is ScalaCheck's and a seed
  * replays the whole case.
  */
final class Rng(initial: Seed):
  private var seed: Seed = initial

  def this(seed: Long) = this(Seed(seed))

  def nextLong(): Long =
    val (value, next) = seed.long
    seed = next
    value

  /** A Long in [0, bound), without modulo bias. */
  def nextLong(bound: Long): Long =
    require(bound > 0, "bound must be positive")
    val limit = Long.MaxValue - (Long.MaxValue % bound)
    var drawn = nextLong() & Long.MaxValue
    while drawn >= limit do drawn = nextLong() & Long.MaxValue
    drawn % bound

  def nextInt(bound: Int): Int = nextLong(bound.toLong).toInt

  def nextInt(): Int = nextLong().toInt

  def nextBoolean(): Boolean = (nextLong() & 1L) == 1L

  def nextDouble(): Double =
    val (value, next) = seed.double
    seed = next
    value

/** A generator of shrink trees, run by ScalaCheck.
  *
  * An Arb draws a value and the tree of smaller values it may shrink to, so a
  * dependent input's shrink redraws its dependants from the same random state
  * and every candidate stays inside its refinement. ScalaCheck draws each
  * case's seed and walks the tree when a property fails, so failures shrink and
  * report as ScalaCheck's do. ref:DEC-native-property-frameworks ref:scalacheck
  * ref:DEC-shrink-within-domain
  */
trait Arb[A]:
  self =>
  def sample(rng: Rng): Tree[A]

  def map[B](f: A => B): Arb[B] = rng => self.sample(rng).map(f)

  /** Values the predicate accepts, drawing again up to attempts times. */
  def filter(accepted: A => Boolean): Arb[A] =
    Arb.bounded(self, 100, "filter")(accepted)

object Arb:
  def apply[A](draw: Rng => Tree[A]): Arb[A] = rng => draw(rng)

  /** A generator of plain values, without shrinks. */
  def from[A](draw: Rng => A): Arb[A] = rng => Tree.leaf(draw(rng))

  def constant[A](value: A): Arb[A] = _ => Tree.leaf(value)

  /** An Int in the range, shrinking toward the value nearest zero. */
  def int(range: Range.Inclusive): Arb[Int] =
    val lo = range.start.toLong
    val hi = range.end.toLong
    val origin = if lo <= 0 && 0 <= hi then 0L else if lo > 0 then lo else hi
    rng =>
      val drawn = lo + (rng.nextLong(hi - lo + 1))
      towards(origin, drawn).map(_.toInt)

  /** Hedgehog's integral shrinks: the origin, then halfway, and so on. */
  private def towards(origin: Long, value: Long): Tree[Long] =
    Tree(value, candidates(origin, value).map(towards(origin, _)))

  private def candidates(origin: Long, value: Long): LazyList[Long] =
    if value == origin then LazyList.empty
    else
      val distance = BigInt(value) - BigInt(origin)
      LazyList
        .iterate(distance)(_ / 2)
        .takeWhile(_ != 0)
        .map(d => (BigInt(value) - d).toLong)
        .distinct

  def boolean: Arb[Boolean] = rng =>
    val value = rng.nextBoolean()
    if value then Tree(true, LazyList(Tree.leaf(false))) else Tree.leaf(false)

  private val specialDoubles = Vector(
    0.0,
    -0.0,
    1.0,
    -1.0,
    Double.NaN,
    Double.PositiveInfinity,
    Double.NegativeInfinity,
    Double.MinPositiveValue,
    Double.MaxValue,
    Double.MinValue
  )

  /** A Double of any bit pattern, special values included, shrinking toward
    * zero.
    */
  def double: Arb[Double] = rng =>
    val value =
      if rng.nextInt(4) == 0 then
        specialDoubles(rng.nextInt(specialDoubles.size))
      else if rng.nextBoolean() then
        java.lang.Double.longBitsToDouble(rng.nextLong())
      else (rng.nextDouble() - 0.5) * 2000.0
    if value == 0.0 then Tree.leaf(value)
    else Tree(value, LazyList(Tree.leaf(0.0)))

  private val specialFloats = Vector(
    0.0f,
    -0.0f,
    1.0f,
    -1.0f,
    Float.NaN,
    Float.PositiveInfinity,
    Float.NegativeInfinity,
    Float.MinPositiveValue,
    Float.MaxValue,
    Float.MinValue
  )

  /** A Float of any bit pattern, special values included, shrinking toward
    * zero.
    */
  def float: Arb[Float] = rng =>
    val value =
      if rng.nextInt(4) == 0 then specialFloats(rng.nextInt(specialFloats.size))
      else if rng.nextBoolean() then
        java.lang.Float.intBitsToFloat(rng.nextInt())
      else ((rng.nextDouble() - 0.5) * 2000.0).toFloat
    if value == 0.0f then Tree.leaf(value)
    else Tree(value, LazyList(Tree.leaf(0.0f)))

  /** One of the values, shrinking toward the first. */
  def element[A](values: Seq[A]): Arb[A] =
    require(values.nonEmpty, "element requires values")
    int(0 to values.size - 1).map(values)

  /** Both values, each shrinking in turn. */
  def bind[A, B, C](first: Arb[A], second: Arb[B])(
      combine: (A, B) => C
  ): Arb[C] = rng =>
    product(first.sample(rng), second.sample(rng)).map(combine.tupled)

  private def product[A, B](a: Tree[A], b: Tree[B]): Tree[(A, B)] =
    Tree(
      (a.value, b.value),
      a.children.map(product(_, b)) #::: b.children.map(product(a, _))
    )

  /** One generator or the other, keeping the chosen one's tree. */
  def choice[A](first: Arb[A], second: Arb[A]): Arb[A] = rng =>
    if rng.nextBoolean() then first.sample(rng) else second.sample(rng)

  /** A list of a length in the range; it shrinks by dropping items, then item
    * by item.
    */
  def list[A](element: Arb[A], range: Range.Inclusive): Arb[List[A]] = rng =>
    val length = range.start + rng.nextInt(range.end - range.start + 1)
    listTree(Vector.fill(length)(element.sample(rng)), range.start)
      .map(_.map(_.value).toList)

  private def listTree[A](
      items: Vector[Tree[A]],
      minimum: Int
  ): Tree[Vector[Tree[A]]] =
    val shorter =
      if items.size <= minimum then LazyList.empty
      else
        val halves = LazyList
          .iterate(items.size / 2)(_ / 2)
          .takeWhile(_ > 0)
          .map(n => items.take(math.max(minimum, items.size - n)))
          .filter(_.size < items.size)
        val single =
          LazyList.range(0, items.size).map(i => items.patch(i, Nil, 1))
        (halves #::: single).distinct
    val smaller = LazyList
      .range(0, items.size)
      .flatMap(i => items(i).children.map(child => items.updated(i, child)))
    Tree(
      items,
      shorter.map(listTree(_, minimum)) #::: smaller.map(listTree(_, minimum))
    )

  /** A generator that depends on a drawn value. Both trees are kept: the
    * source's shrinks redraw the dependant from the same random state, and the
    * dependant shrinks on its own.
    */
  def flatMap[A, B](source: Arb[A])(next: A => Arb[B]): Arb[B] = rng =>
    val sourceTree = source.sample(rng)
    val seed = rng.nextLong()
    def draw(tree: Tree[A]): Tree[B] = next(tree.value).sample(Rng(seed))
    def compose(sourceNode: Tree[A], result: Tree[B]): Tree[B] =
      Tree(
        result.value,
        sourceNode.children.map(child =>
          compose(child, draw(child))
        ) #::: result.children.map(compose(sourceNode, _))
      )
    compose(sourceTree, draw(sourceTree))

  /** Draws until the predicate accepts a value, at most attempts times; the
    * tree keeps only accepted values.
    */
  def bounded[A](source: Arb[A], attempts: Int, label: String)(
      accepted: A => Boolean
  ): Arb[A] = rng =>
    Iterator
      .continually(source.sample(rng).filter(accepted))
      .take(attempts)
      .collectFirst { case Some(tree) => tree }
      .getOrElse(
        throw IllegalArgumentException(
          s"constructor generation exhausted $attempts attempts for $label"
        )
      )

/** Runs properties on ScalaCheck. */
object LawSpecProperty:
  /** LAWSPEC_SEED fixes ScalaCheck's seed, so a run can be repeated exactly. */
  def seed: Option[Long] = sys.env.get("LAWSPEC_SEED").map(_.toLong)

  /** Checks the property on cases drawn by the generator. A failing case is
    * shrunk along its tree, and the smallest failure is rethrown with the seed
    * that replays it.
    */
  def checkAll[A](label: String, iterations: Int, arb: Arb[A])(
      property: A => Unit
  ): Unit =
    val initial = seed.getOrElse(scala.util.Random.nextLong())
    val gen: Gen[Tree[A]] = Gen.long.map(n => arb.sample(Rng(Seed(n))))
    def holds(tree: Tree[A]): Boolean =
      try
        property(tree.value)
        true
      catch case _: Throwable => false
    val shrink: Shrink[Tree[A]] = Shrink.withLazyList(_.children)
    val prop = Prop.forAll(gen)((tree: Tree[A]) => Prop(holds(tree)))(using
      identity,
      shrink,
      _ => Pretty(_ => label)
    )
    val parameters = Test.Parameters.default
      .withMinSuccessfulTests(iterations)
      .withMaxDiscardRatio(5f)
      .withWorkers(1)
      .withInitialSeed(Seed(initial))
      .withTestCallback(Test.Parameters.default.testCallback)
    val result = Test.check(parameters, prop)
    result.status match
      case Test.Passed | Test.Proved(_) => ()
      case Test.Failed(arguments, _)    =>
        val smallest = arguments.headOption.map(_.arg.asInstanceOf[Tree[A]])
        val failure = smallest.flatMap(tree =>
          try
            property(tree.value)
            None
          catch case error: Throwable => Some(error)
        )
        val replay =
          s"$label: failed after ${result.succeeded} cases (LAWSPEC_SEED=$initial replays it)"
        failure match
          case Some(error) =>
            throw AssertionError(replay + ": " + error.getMessage, error)
          case None => throw AssertionError(replay)
      case Test.PropException(_, error, _) =>
        throw AssertionError(
          s"$label: (LAWSPEC_SEED=$initial replays it): ${error.getMessage}",
          error
        )
      case Test.Exhausted =>
        throw AssertionError(
          s"$label: gave up after ${result.discarded} discarded cases (LAWSPEC_SEED=$initial)"
        )

/** parallel: a suite whose tests run at the same time, on a pool of a thread
  * per processor. When the suite starts, the bodies of the tests it will run
  * start together on the pool; ScalaTest then runs each test as usual, which
  * waits for its body's outcome, so ScalaTest still reports each test, selects
  * them by name and skips ignored ones.
  */
trait LawSpecParallel extends org.scalatest.funsuite.AnyFunSuite {
  private val lawspecBodies =
    scala.collection.mutable.LinkedHashMap[String, () => Any]()
  private val lawspecStarted = java.util.concurrent
    .ConcurrentHashMap[String, java.util.concurrent.Future[Any]]()

  private lazy val lawspecPool: java.util.concurrent.ExecutorService =
    java.util.concurrent.Executors.newFixedThreadPool(
      Runtime.getRuntime.availableProcessors(),
      (task: Runnable) => {
        val thread = Thread(task, "lawspec-parallel")
        thread.setDaemon(true)
        thread
      }
    )

  /** Registers a test whose body runs on the pool, started with the suite's
    * others.
    */
  protected def parallelTest(testName: String)(testFun: => Any): Unit = {
    lawspecBodies(testName) = () => testFun
    test(testName) {
      val started = lawspecStarted.get(testName)
      val outcome =
        if (started == null) lawspecPool.submit(() => lawspecBodies(testName)())
        else started
      try outcome.get()
      catch {
        case failed: java.util.concurrent.ExecutionException =>
          throw failed.getCause
      }
    }
  }

  override protected def runTests(
      testName: Option[String],
      args: org.scalatest.Args
  ): org.scalatest.Status = {
    val selected = testName match {
      case Some(name) => List(name)
      case None       =>
        args.filter(testNames, tags, suiteId).collect { case (name, false) =>
          name
        }
    }
    for (name <- selected; body <- lawspecBodies.get(name))
      lawspecStarted.put(name, lawspecPool.submit(() => body()))
    super.runTests(testName, args)
  }
}
