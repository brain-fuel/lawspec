package lawspec.runtime

import java.util.{Map => JMap}
import scala.jdk.CollectionConverters.*
import lawspec.runtime.LawSpecRuntime as Runtime
import lawspec.runtime.LawSpecSchema.{Codec, Named}
import lawspec.runtime.LawSpecScala as Native

/**
 * Codecs between Scala's own types and LawSpec's values.
 *
 * Adapters work with Scala's immutable types: List, Option, Either, Set, Map, BigInt, BigDecimal,
 * FiniteDuration and IArray. Each codec converts between them and LawSpec's values and checks the
 * result, so a law never sees a native value outside its domain. ref:DEC-native-bindings-typed-identity
 */
object LawSpecScalaCodecs:
  private def fresh(): JMap[String, Object] = Native.symbols()

  private def codec[T](
      schema: LawSpecSchema,
      tpe: Named,
      bits: Int,
      symbols: JMap[String, Object],
      encode: T => Runtime.Value,
      decode: Runtime.Value => T,
  ): Codec[T] =
    schema.codec[T](tpe, bits, symbols, (value: T) => encode(value), (value: Runtime.Value) => decode(value))

  /** A data value built from its constructor's fields; a List from Nil or Cons. */
  def construct(
      schema: LawSpecSchema,
      tpe: Named,
      tag: String,
      fields: List[Runtime.Value],
      bits: Int,
      symbols: JMap[String, Object] = fresh(),
  ): Runtime.Value =
    if tpe.name() != "List" then schema.construct(tpe, tag, fields.asJava, bits, symbols)
    else
      val values: List[Runtime.Value] = (tag, fields) match
        case ("List::Nil", Nil) => Nil
        case ("List::Cons", head :: tail :: Nil) =>
          head :: tail.data().asInstanceOf[java.util.List[?]].asScala.toList.map(_.asInstanceOf[Runtime.Value])
        case _ => throw IllegalArgumentException("invalid List constructor or field count")
      Runtime.Value(LawSpecSchema.key(tpe), values.asJava)

  /** Dispatches on a checked value's constructor; a List is Nil or Cons. */
  def matching(
      schema: LawSpecSchema,
      tpe: Named,
      value: Runtime.Value,
      bits: Int,
      symbols: JMap[String, Object],
  )(branch: (String, IndexedSeq[Runtime.Value]) => Runtime.Value): Runtime.Value =
    // Values in generated code are checked where they are built, decoded or
    // drawn, so matching only dispatches.
    if tpe.name() == "List" then
      val values = value.data().asInstanceOf[java.util.List[?]].asScala.toVector.map(_.asInstanceOf[Runtime.Value])
      if values.isEmpty then branch("List::Nil", Vector.empty)
      else branch("List::Cons", Vector(values.head, Runtime.Value(value.`type`(), values.tail.asJava)))
    else
      val data = value.data().asInstanceOf[Runtime.Data]
      branch(data.tag(), data.fields().asScala.toVector)

  /** A scalar natively, in Scala's type for it (see the target's documentation). */
  def scalar[T](schema: LawSpecSchema, name: String, bits: Int): Codec[T] =
    val tpe = Named(name)
    val result: Codec[?] = name match
      case "Integer" | "BigInt" | "BigUInt" | "UInt64" | "IntSize" | "UIntSize" | "UIntPtr" =>
        codec[BigInt](schema, tpe, bits, fresh(),
          value => Runtime.fromNative(name, value.bigInteger, bits),
          value => BigInt(Runtime.toNative(name, value, bits).asInstanceOf[java.math.BigInteger]))
      case "Decimal" =>
        codec[BigDecimal](schema, tpe, bits, fresh(),
          value => Runtime.fromNative(name, value.bigDecimal, bits),
          // Exact, as a Decimal is: Scala's default context would round to 34 digits.
          value => new BigDecimal(Runtime.toNative(name, value, bits).asInstanceOf[java.math.BigDecimal], java.math.MathContext.UNLIMITED))
      case "Bytes" =>
        codec[IArray[Byte]](schema, tpe, bits, fresh(),
          value => Runtime.fromNative(name, IArray.genericWrapArray(value).toArray, bits),
          value => IArray.unsafeFromArray(Runtime.toNative(name, value, bits).asInstanceOf[Array[Byte]]))
      case "CodePointText" => codePointText(schema, bits)
      case "Unit" => unit(schema, bits)
      case "Null" => nullValue(schema, bits)
      case "Undefined" => undefined(schema, bits)
      case "Symbol" => symbol(schema, bits)
      case _ =>
        codec[Any](schema, tpe, bits, fresh(),
          value => Runtime.fromNative(name, value, bits),
          value => Runtime.toNative(name, value, bits))
    result.asInstanceOf[Codec[T]]

  /** An Integer result: any of Int, Long and BigInt, checked as an integer. */
  def integer(value: Int | Long | BigInt, bits: Int): Runtime.Value = value match
    case n: Int => Runtime.fromNative("Integer", java.math.BigInteger.valueOf(n.toLong), bits)
    case n: Long => Runtime.fromNative("Integer", java.math.BigInteger.valueOf(n), bits)
    case n: BigInt => Runtime.fromNative("Integer", n.bigInteger, bits)

  def list[T](schema: LawSpecSchema, bits: Int, element: Codec[T], symbols: JMap[String, Object] = fresh()): Codec[List[T]] =
    val inner = schema.list(element, bits, symbols)
    codec[List[T]](schema, inner.`type`(), bits, symbols,
      values => inner.encode(values.asJava),
      value => inner.decode(value).asScala.toList)

  def option[T](schema: LawSpecSchema, bits: Int, element: Codec[T], symbols: JMap[String, Object] = fresh()): Codec[Option[T]] =
    val inner = schema.maybe(element, bits, symbols)
    codec[Option[T]](schema, inner.`type`(), bits, symbols,
      {
        case Some(value) => inner.encode(Runtime.Just[T](value))
        case None => inner.encode(Runtime.Nothing[T]())
      },
      value => inner.decode(value) match
        case just: Runtime.Just[T] @unchecked => Some(just.value())
        case _ => None)

  def either[L, R](
      schema: LawSpecSchema,
      bits: Int,
      left: Codec[L],
      right: Codec[R],
      symbols: JMap[String, Object] = fresh(),
  ): Codec[Either[L, R]] =
    val inner = schema.either(left, right, bits, symbols)
    codec[Either[L, R]](schema, inner.`type`(), bits, symbols,
      {
        case Left(value) => inner.encode(Runtime.Left[L, R](value))
        case Right(value) => inner.encode(Runtime.Right[L, R](value))
      },
      value => inner.decode(value) match
        case item: Runtime.Left[L, R] @unchecked => Left(item.value())
        case item: Runtime.Right[L, R] @unchecked => Right(item.value()))

  /** A Duration natively: a FiniteDuration of whole microseconds. */
  def duration(schema: LawSpecSchema, bits: Int, symbols: JMap[String, Object] = fresh()): Codec[scala.concurrent.duration.FiniteDuration] =
    val inner = schema.duration(bits, symbols)
    codec[scala.concurrent.duration.FiniteDuration](schema, inner.`type`(), bits, symbols,
      value => inner.encode(java.time.Duration.ofNanos(value.toNanos)),
      value => scala.concurrent.duration.FiniteDuration(inner.decode(value).toNanos, java.util.concurrent.TimeUnit.NANOSECONDS).toCoarsest)

  /** A Set natively, in canonical order when LawSpec builds it. */
  def set[T](schema: LawSpecSchema, bits: Int, element: Codec[T], symbols: JMap[String, Object] = fresh()): Codec[Set[T]] =
    val inner = schema.set(element, bits, symbols)
    codec[Set[T]](schema, inner.`type`(), bits, symbols,
      values => inner.encode(values.asJava),
      value => scala.collection.immutable.ListSet.from(inner.decode(value).asScala))

  /** A KeyVal natively, in canonical key order when LawSpec builds it. */
  def keyVal[K, V](
      schema: LawSpecSchema,
      bits: Int,
      keys: Codec[K],
      values: Codec[V],
      symbols: JMap[String, Object] = fresh(),
  ): Codec[Map[K, V]] =
    val inner = schema.keyVal(keys, values, bits, symbols)
    codec[Map[K, V]](schema, inner.`type`(), bits, symbols,
      map => inner.encode(map.asJava),
      value => scala.collection.immutable.ListMap.from(inner.decode(value).asScala))

  /** A Queue natively: an immutable Queue from its first item. */
  def queue[T](schema: LawSpecSchema, bits: Int, element: Codec[T], symbols: JMap[String, Object] = fresh()): Codec[scala.collection.immutable.Queue[T]] =
    val inner = schema.sequence("Queue", element, bits, symbols)
    codec[scala.collection.immutable.Queue[T]](schema, inner.`type`(), bits, symbols,
      items => inner.encode(java.util.ArrayDeque(items.asJava)),
      value => scala.collection.immutable.Queue.from(inner.decode(value).asScala))

  /** A Stack natively: a List from its top. */
  def stack[T](schema: LawSpecSchema, bits: Int, element: Codec[T], symbols: JMap[String, Object] = fresh()): Codec[List[T]] =
    val inner = schema.sequence("Stack", element, bits, symbols)
    codec[List[T]](schema, inner.`type`(), bits, symbols,
      items => inner.encode(java.util.ArrayDeque(items.asJava)),
      value => inner.decode(value).asScala.toList)

  /** A Deque natively: a Vector from its first item. */
  def deque[T](schema: LawSpecSchema, bits: Int, element: Codec[T], symbols: JMap[String, Object] = fresh()): Codec[Vector[T]] =
    val inner = schema.sequence("Deque", element, bits, symbols)
    codec[Vector[T]](schema, inner.`type`(), bits, symbols,
      items => inner.encode(java.util.ArrayDeque(items.asJava)),
      value => inner.decode(value).asScala.toVector)

  def unit(schema: LawSpecSchema, bits: Int): Codec[Unit] =
    codec[Unit](schema, Named("Unit"), bits, fresh(), _ => Runtime.absent("Unit"), _ => ())

  def nullValue(schema: LawSpecSchema, bits: Int): Codec[Native.Null] =
    codec[Native.Null](schema, Named("Null"), bits, fresh(), _ => Runtime.absent("Null"), _ => Native.Null)

  def undefined(schema: LawSpecSchema, bits: Int): Codec[Native.Undefined] =
    codec[Native.Undefined](schema, Named("Undefined"), bits, fresh(), _ => Runtime.absent("Undefined"), _ => Native.Undefined)

  def symbol(schema: LawSpecSchema, bits: Int): Codec[Native.Symbol] =
    codec[Native.Symbol](schema, Named("Symbol"), bits, fresh(),
      value => Runtime.Value("Symbol", value.token),
      value => Native.Symbol(value.data().asInstanceOf[Runtime.SymbolValue]))

  def codePointText(schema: LawSpecSchema, bits: Int): Codec[IArray[Int]] =
    codec[IArray[Int]](schema, Named("CodePointText"), bits, fresh(),
      value => Runtime.sequence("CodePointText", IArray.genericWrapArray(value).toArray),
      value => IArray.from(value.data().asInstanceOf[java.util.List[?]].asScala.map(_.asInstanceOf[Int])))

  def nullable[T](schema: LawSpecSchema, bits: Int, element: Codec[T], symbols: JMap[String, Object] = fresh()): Codec[Native.Nullable[T]] =
    val tpe = Named("Nullable", element.`type`())
    codec[Native.Nullable[T]](schema, tpe, bits, symbols,
      value =>
        val payload = value match
          case Native.Nullable.Null => Runtime.Presence(false, null)
          case Native.Nullable.Present(inner) => Runtime.Presence(true, LawSpecSchema.encodeField(element, inner, "present"))
        Runtime.Value(LawSpecSchema.key(tpe), payload),
      value =>
        val payload = value.data().asInstanceOf[Runtime.Presence]
        if payload.present() then Native.Nullable.Present(element.decode(payload.value())) else Native.Nullable.Null)

  def optional[T](schema: LawSpecSchema, bits: Int, element: Codec[T], symbols: JMap[String, Object] = fresh()): Codec[Native.Optional[T]] =
    val tpe = Named("Optional", element.`type`())
    codec[Native.Optional[T]](schema, tpe, bits, symbols,
      value =>
        val payload = value match
          case Native.Optional.Undefined => Runtime.Presence(false, null)
          case Native.Optional.Present(inner) => Runtime.Presence(true, LawSpecSchema.encodeField(element, inner, "present"))
        Runtime.Value(LawSpecSchema.key(tpe), payload),
      value =>
        val payload = value.data().asInstanceOf[Runtime.Presence]
        if payload.present() then Native.Optional.Present(element.decode(payload.value())) else Native.Optional.Undefined)
