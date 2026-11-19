package dev.goforge.lawspec;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;

/**
 * The LawSpec compiler API, with the methods of the npm package's {@code createCompiler()}. Each
 * method takes the request object as JSON text, without {@code method} (and with {@code
 * schemaVersion} optional, 5 by default), and returns the response object as JSON text, exactly as
 * the npm package and the WebAssembly core answer it. Each call is one run of {@code lawspec --api
 * <method>}, which reads the request on standard input; the request is completed and answered by
 * the binary, not here.
 *
 * <p>
 * See the compiler API reference (docs/reference/api.md) for the request and response shapes.
 */
public final class Compiler
{
  private final Installation installation;

  Compiler(Installation installation)
  {
    this.installation = installation;
  }

  /**
   * Queries the prelude.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String prelude(String request)
  {
    return call("prelude", request);
  }

  /**
   * Inspects the generated and bound interfaces for a target.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String inspect(String request)
  {
    return call("inspect", request);
  }

  /**
   * Gives authoring advice.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String advise(String request)
  {
    return call("advise", request);
  }

  /**
   * Formats sources.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String format(String request)
  {
    return call("format", request);
  }

  /**
   * Checks sources.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String check(String request)
  {
    return call("check", request);
  }

  /**
   * Expands sources.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String expand(String request)
  {
    return call("expand", request);
  }

  /**
   * Explains laws.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String explain(String request)
  {
    return call("explain", request);
  }

  /**
   * Lists proof tasks.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String proofTasks(String request)
  {
    return call("proofTasks", request);
  }

  /**
   * Plans generation.
   *
   * @param request the request object as JSON
   * @return the response object as JSON
   */
  public String planGeneration(String request)
  {
    return call("planGeneration", request);
  }

  /**
   * Sends one request for a method.
   *
   * @param method the API method
   * @param request the request object as JSON
   * @return the response object as JSON
   * @throws LawSpecException if the binary cannot run or exits with a code other than 0
   */
  public String call(String method, String request)
  {
    ProcessBuilder builder = new ProcessBuilder(installation.command(List.of("--api", method)))
        .redirectError(ProcessBuilder.Redirect.INHERIT);
    builder.environment().putAll(installation.environment());
    try
    {
      Process process = builder.start();
      // The request is written while the response is read, so neither pipe fills.
      CompletableFuture<Void> writer = CompletableFuture.runAsync(() -> {
        try (OutputStream in = process.getOutputStream())
        {
          in.write(request.getBytes(StandardCharsets.UTF_8));
        }
        catch (IOException e)
        {
          throw new UncheckedIOException(e);
        }
      });
      byte[] response;
      try (InputStream out = process.getInputStream())
      {
        response = out.readAllBytes();
      }
      int code = process.waitFor();
      writer.join();
      if (code != 0)
      {
        throw new LawSpecException("lawspec --api " + method + " exited with code " + code);
      }
      return new String(response, StandardCharsets.UTF_8);
    }
    catch (IOException | CompletionException e)
    {
      throw new LawSpecException("lawspec --api " + method + " failed: " + e.getMessage(), e);
    }
    catch (InterruptedException e)
    {
      Thread.currentThread().interrupt();
      throw new LawSpecException("Interrupted during lawspec --api " + method, e);
    }
  }
}
