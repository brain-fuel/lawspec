// User-owned LawSpec adapter: adding through a server process, over the
// typed channel ends generated from the Serve and Hire protocols.
package example

import lawspec.runtime.LawSpecRuntime
import lawspec.sessions.Hire
import lawspec.sessions.Serve
import scala.concurrent.{ExecutionContext, Future, blocking}

object Sessions {
  private given ExecutionContext = ExecutionContext.global

  // The server: receive two numbers, send their sum.
  private def serve(server: Serve.First.ReceiveInt32Step1): Unit = {
    val a = server.receive()
    val b = a.next().receive()
    b.next().send(a.value().toLong + b.value().toLong)
  }

  // The client: send both numbers, receive the sum.
  private def ask(client: Serve.Second.SendInt32Step1, a: Int, b: Int): Long = {
    val afterA = client.send(a)
    val afterB = afterA.send(b)
    afterB.receive().value()
  }

  private def spawn(task: => Unit): LawSpecRuntime.Spawned[Void] =
    LawSpecRuntime.spawn((() => task): Runnable)

  def add(value0: Int, value1: Int): Future[scala.Int | scala.Long | scala.math.BigInt] = Future {
    blocking {
      val ends = Serve.open()
      val server = spawn(serve(ends.first()))
      val sum = ask(ends.second(), value0, value1)
      server.join()
      BigInt(sum)
    }
  }

  // A manager is handed the server's end over a Hire channel and serves it.
  def addHired(value0: Int, value1: Int): Future[scala.Int | scala.Long | scala.math.BigInt] = Future {
    blocking {
      val serveEnds = Serve.open()
      val hire = Hire.open()
      val manager = spawn(serve(hire.second().receive().value()))
      hire.first().send(serveEnds.first())
      val sum = ask(serveEnds.second(), value0, value1)
      manager.join()
      BigInt(sum)
    }
  }
}
