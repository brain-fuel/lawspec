package lawspec.runtime

/** Native support types whose domains Scala's own types do not cover.
  *
  * Scala's Option has one empty case, so Nullable and Optional keep an absent
  * value apart from a present null, as a law's Maybe, Nullable and Optional
  * types require. Null and Undefined are values of their own, and a Symbol is
  * compared by its identity. ref:DEC-algebraic-maybe-either
  */
object LawSpecScala:
  /** What generated code passes along: a law's handlers, symbols and scoped
    * state.
    */
  type Symbols = java.util.Map[String, Object]

  /** A fresh, empty symbols map. */
  def symbols(): Symbols = java.util.HashMap[String, Object]()

  /** A value of a native call, as the type it is known to have. */
  def cast[T](value: Any): T = value.asInstanceOf[T]

  /** The handler installed in symbols for an ability, as its trait. */
  def handler[T](symbols: Symbols, ability: String): T =
    LawSpecRuntime.handler(symbols, ability).asInstanceOf[T]

  /** The value of an operation that fails with E, natively an Either: a Left
    * becomes the failure the law sees, as LawSpecRuntime.Fail does for the
    * other JVM targets.
    */
  def orFail[E, R](result: Either[E, R]): R = result match
    case Right(value)  => value
    case Left(failure) => throw LawSpecRuntime.Fail(failure)

  /** A value that may be null: Null, or Present with the value. */
  enum Nullable[+T]:
    case Null
    case Present(value: T)

  /** A value that may be undefined: Undefined, or Present with the value. */
  enum Optional[+T]:
    case Undefined
    case Present(value: T)

  /** The only value of the Null type. */
  case object Null

  /** The type of Null. */
  type Null = Null.type

  /** The only value of the Undefined type. */
  case object Undefined

  /** The type of Undefined. */
  type Undefined = Undefined.type

  /** A Symbol: equal to itself only, even after a checked round trip. */
  final class Symbol private[runtime] (
      private[runtime] val token: LawSpecRuntime.SymbolValue
  ):
    def this(description: String) =
      this(LawSpecRuntime.SymbolValue(description))

    def description: String = token.description()

    override def equals(other: Any): Boolean = other match
      case symbol: Symbol => token eq symbol.token
      case _              => false

    override def hashCode: Int = System.identityHashCode(token)

    override def toString: String = s"Symbol($description)"
