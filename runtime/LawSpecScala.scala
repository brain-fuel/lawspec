package lawspec.runtime

/**
 * Native support types whose domains Scala's own types do not cover.
 *
 * Scala's Option has one empty case, so Nullable and Optional keep an absent value apart from a
 * present null, as a law's Maybe, Nullable and Optional types require. Null and Undefined are
 * values of their own, and a Symbol is compared by its identity. ref:DEC-algebraic-maybe-either
 */
object LawSpecScala:
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
  final class Symbol private[runtime] (private[runtime] val token: LawSpecRuntime.SymbolValue):
    def this(description: String) = this(LawSpecRuntime.SymbolValue(description))

    def description: String = token.description()

    override def equals(other: Any): Boolean = other match
      case symbol: Symbol => token eq symbol.token
      case _ => false

    override def hashCode: Int = System.identityHashCode(token)

    override def toString: String = s"Symbol($description)"
