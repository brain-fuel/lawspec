package till

/**
 * The application's own money type. Its constructor and accessor are
 * written out: the Java model reads it through Groovy's joint-compilation
 * stubs, which leave a record's out.
 */
@groovy.transform.CompileStatic
record Cash(long cents) {
  Cash(long cents) { this.cents = cents }

  long cents() { cents }
}
