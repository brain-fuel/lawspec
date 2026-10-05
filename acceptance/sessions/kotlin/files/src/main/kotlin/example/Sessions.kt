// User-owned LawSpec adapter: adding through a server process, over the
// typed channel ends generated from the Serve and Hire protocols.
package example

import java.math.BigInteger
import lawspec.runtime.LawSpecRuntime
import lawspec.sessions.Hire
import lawspec.sessions.Serve

object Sessions {
    // The server: receive two numbers, send their sum.
    private fun serve(server: Serve.First.ReceiveInt32Step1) {
        val a = server.receive()
        val b = a.next.receive()
        b.next.send(a.value.toLong() + b.value)
    }

    // The client: send both numbers, receive the sum.
    private fun ask(client: Serve.Second.SendInt32Step1, a: Int, b: Int): Long {
        val afterA = client.send(a)
        val afterB = afterA.send(b)
        return afterB.receive().value
    }

    fun add(value0: kotlin.Int, value1: kotlin.Int): Number {
        val ends = Serve.open()
        val server = LawSpecRuntime.spawn { serve(ends.first) }
        val sum = ask(ends.second, value0, value1)
        server.join()
        return BigInteger.valueOf(sum)
    }

    // A manager is handed the server's end over a Hire channel and serves it.
    fun addHired(value0: kotlin.Int, value1: kotlin.Int): Number {
        val serve = Serve.open()
        val hire = Hire.open()
        val manager = LawSpecRuntime.spawn { serve(hire.second.receive().value) }
        hire.first.send(serve.first)
        val sum = ask(serve.second, value0, value1)
        manager.join()
        return BigInteger.valueOf(sum)
    }
}
