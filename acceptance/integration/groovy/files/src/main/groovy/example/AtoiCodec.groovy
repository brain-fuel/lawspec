package example

@groovy.transform.CompileStatic
final class AtoiCodec {
  static String itoa(int value) { Integer.toString(value) }

  static int atoi(String value) { Integer.parseInt(value) }
}
