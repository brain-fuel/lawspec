package dev.goforge.lawspec;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import sun.misc.Signal;
import sun.misc.SignalHandler;

/**
 * The {@code lawspec} CLI on the JVM, and the entry points of its API. {@code java -jar
 * lawspec.jar <arguments>} runs the native {@code lawspec} with the arguments, the working
 * directory, the environment and the standard streams passed through, and exits with its exit code.
 * The launcher holds no LawSpec logic; see {@link Installation} for how it finds the binary.
 */
public final class LawSpec
{
  private LawSpec()
  {
  }

  /**
   * Runs {@code lawspec} and exits as it does. A signal this process receives ({@code SIGINT},
   * {@code SIGTERM}, {@code SIGHUP}) is passed on to it, and when it ends by that signal this
   * process ends by the same signal, as if it had been run directly. A failure to find, unpack or
   * verify the binary is reported on standard error and exits with code 1.
   *
   * @param arguments the CLI arguments
   */
  public static void main(String[] arguments)
  {
    int code;
    try
    {
      Process process = start(Installation.locate(), Arrays.asList(arguments), null);
      AtomicReference<Signal> received = new AtomicReference<>();
      for (String name : new String[] {"INT", "TERM", "HUP"})
      {
        Signal.handle(new Signal(name), signal -> {
          received.set(signal);
          forward(process, name);
        });
      }
      code = waitFor(process);
      Signal signal = received.get();
      // A child that a signal ended exits with 128 plus its number.
      if (signal != null && code == 128 + signal.getNumber())
      {
        Signal.handle(signal, SignalHandler.SIG_DFL);
        signalSelf(signal);
      }
    }
    catch (LawSpecException e)
    {
      System.err.println("lawspec: " + e.getMessage());
      code = 1;
    }
    System.exit(code);
  }

  // Ends this process by a signal, its handler restored to the default. Signal.raise refuses a
  // signal with the default handler, so the signal is sent as kill(1) sends it.
  private static void signalSelf(Signal signal)
  {
    try
    {
      new ProcessBuilder("/bin/kill", "-s", signal.getName(),
          Long.toString(ProcessHandle.current().pid())).start().waitFor();
      Thread.sleep(1000);
    }
    catch (IOException | InterruptedException e)
    {
      // Exit with the code instead.
    }
  }

  // Sends a signal by name to the binary; the JDK can send only SIGTERM and SIGKILL itself.
  private static void forward(Process process, String name)
  {
    try
    {
      new ProcessBuilder("/bin/kill", "-s", name, Long.toString(process.pid())).start();
    }
    catch (IOException e)
    {
      process.destroy();
    }
  }

  /**
   * Runs {@code lawspec} with the standard streams of this process and waits for it.
   *
   * @param installation the installation to run
   * @param arguments the CLI arguments
   * @param directory the working directory, or {@code null} for this process's
   * @return its exit code
   * @throws LawSpecException if it cannot be started or the wait is interrupted
   */
  public static int run(Installation installation, List<String> arguments, Path directory)
  {
    return waitFor(start(installation, arguments, directory));
  }

  private static Process start(Installation installation, List<String> arguments, Path directory)
  {
    ProcessBuilder builder = new ProcessBuilder(installation.command(arguments)).inheritIO();
    if (directory != null)
    {
      builder.directory(directory.toFile());
    }
    builder.environment().putAll(installation.environment());
    try
    {
      return builder.start();
    }
    catch (IOException e)
    {
      throw new LawSpecException("Cannot start " + installation.binary() + ": " + e.getMessage(),
          e);
    }
  }

  private static int waitFor(Process process)
  {
    // The binary stops with the JVM: a shutdown ends it too.
    Thread stop = new Thread(process::destroy, "lawspec-stop");
    Runtime.getRuntime().addShutdownHook(stop);
    try
    {
      return process.waitFor();
    }
    catch (InterruptedException e)
    {
      process.destroy();
      Thread.currentThread().interrupt();
      throw new LawSpecException("Interrupted while lawspec ran", e);
    }
    finally
    {
      try
      {
        Runtime.getRuntime().removeShutdownHook(stop);
      }
      catch (IllegalStateException e)
      {
        // The JVM is shutting down; the hook runs.
      }
    }
  }

  /**
   * Returns the compiler API, as the npm package's {@code createCompiler()} does, over the
   * installation {@link Installation#locate()} finds.
   *
   * @return the compiler
   */
  public static Compiler createCompiler()
  {
    return new Compiler(Installation.locate());
  }

  /**
   * Returns the compiler API over an installation.
   *
   * @param installation the installation whose binary answers the requests
   * @return the compiler
   */
  public static Compiler createCompiler(Installation installation)
  {
    return new Compiler(installation);
  }
}
