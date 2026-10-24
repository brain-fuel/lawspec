package vault

// Application code the vault's bindings name: a vault that throws its own
// exceptions, which lawspec.edn maps to the operation's failures.
final class Overdraft(message: String) extends RuntimeException(message)

final class FrozenVault extends RuntimeException("frozen")

final class NativeVault {
  private val balance = 1000L

  def withdraw(cents: Long): Long =
    if (cents < 0) throw FrozenVault()
    else if (cents > balance) throw Overdraft(s"over the balance by ${cents - balance}")
    else balance - cents
}

// The bound adapter: the balance a vault opens with.
object Opening {
  def balance(value: Unit): Long = 1000L
}
