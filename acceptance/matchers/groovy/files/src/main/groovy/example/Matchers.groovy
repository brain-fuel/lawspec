// User-owned LawSpec adapters for the matchers example.
package example

import java.util.ArrayList
import java.util.LinkedHashSet
import java.util.List
import java.util.regex.Matcher
import java.util.regex.Pattern

@groovy.transform.CompileStatic
final class Matchers {
  private static final Pattern WORDS = Pattern.compile('[a-z0-9]+')

  // (List (Int32) -> List (Int32))
  static java.util.List<Integer> sortItems(
      java.util.List<Integer> value0) {
    List<Integer> items = new ArrayList<>(value0)
    items.sort { Integer a, Integer b -> a <=> b }
    return items
  }

  // (List (Text) -> List (Text))
  static java.util.List<String> uniqueTags(
      java.util.List<String> value0) {
    List<String> tags = new ArrayList<>(new LinkedHashSet<>(value0))
    return tags
  }

  // (Int32 -> (Int32 -> Float64))
  static double average(int value0, int value1) {
    return ((double) value0 + (double) value1) / 2
  }

  // (Text -> Text)
  static String slug(String value0) {
    List<String> words = new ArrayList<>()
    Matcher m = WORDS.matcher(value0.toLowerCase(java.util.Locale.ROOT))
    while (m.find()) words.add(m.group())
    return String.join('-', words)
  }

  // (Int32 -> example.matchers::type::Order)
  static lawspec.data.Order ship(int value0) {
    return new lawspec.data.Order.Shipped(value0, 'post')
  }
}
