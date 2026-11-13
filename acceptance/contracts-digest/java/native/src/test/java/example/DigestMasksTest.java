package example;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.Map;
import lawspec.data.Account;
import lawspec.definitions.example.Digest;
import lawspec.runtime.LawSpecDataSchema;
import lawspec.runtime.LawSpecMasks;
import lawspec.runtime.LawSpecRuntime;
import org.junit.jupiter.api.Test;

/**
 * A digest needs no key: a specification's digest, the runtime's and a record's native rendering
 * are one text.
 */
final class DigestMasksTest
{
  private static final List<String> TEXTS = List.of("", "abc", "GB82WEST12345698765432",
      "a\u00e9\u20ac\uD83D\uDE00".repeat(300), "x".repeat(5121));

  // BLAKE3 of no bytes and of "abc", as b3sum prints them; the first is the first of the official
  // test vectors (test/fixtures/blake3-official).
  private static final String[][] PUBLISHED =
      {{"", "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"},
          {"abc", "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"},};

  private static final String IBAN = "GB82WEST12345698765432";

  @Test
  void maskDigestInASpecificationIsTheRuntimeMaskDigest()
  {
    for (String text : TEXTS)
    {
      String shown = Digest.fingerprint(Map.of(), text);
      assertEquals(LawSpecMasks.maskDigest(text), shown);
      assertEquals(LawSpecMasks.maskDigestBlake3(text), shown);
      String scoped = Digest.fingerprintIn(Map.of(), "orders", text);
      assertEquals(LawSpecMasks.maskDigestIn("orders", text), scoped);
      assertEquals(LawSpecMasks.maskDigestBlake3In("orders", text), scoped);
      assertNotEquals(shown, scoped);
    }
    for (String[] row : PUBLISHED)
    {
      assertEquals("digest:" + row[1], Digest.fingerprint(Map.of(), row[0]));
    }
  }

  @Test
  void aRecordShowsItsDigestsNativelyWithNoKeySet()
  {
    var account = new Account("ann", IBAN, IBAN);
    String shown = Digest.maskedAccount(Map.of(), account);
    assertEquals(account.toString(), shown);
    assertEquals("Account{owner=ann"
        + ", iban=digest:bef19ccbcf87f759cb18235af8a4d031a4cd89369514a9300e348803fe129d02"
        + ", reference=digest:c88e885494a2d3f82a49e3efbda8ab5dad1560ac499caa380ba9db31abb5a727}",
        shown);
    assertFalse(("" + account).contains(IBAN));
    assertTrue(account.toUnmaskedString().contains(IBAN));
  }

  @Test
  void aFieldHasItsOwnContext()
  {
    String shown = new Account("ann", IBAN, IBAN).toString();
    assertTrue(shown.contains(LawSpecMasks.maskDigestIn("example.digest.Account.iban", IBAN)));
    assertTrue(
        shown.contains(LawSpecMasks.maskDigestIn("example.digest.Account.reference", IBAN)));
    assertFalse(shown.contains(LawSpecMasks.maskDigest(IBAN)));
  }

  @Test
  void aHalfOfASurrogatePairIsHashedAsTheReplacementCharacter()
  {
    String[][] pairs = {{"\uD800", "\ufffd"}, {"\uDC00", "\ufffd"}, {"a\uD83D", "a\ufffd"}};
    for (String[] pair : pairs)
    {
      assertEquals(LawSpecMasks.maskDigest(pair[1]), LawSpecMasks.maskDigest(pair[0]));
      assertEquals(LawSpecMasks.maskDigestIn("orders", pair[1]),
          LawSpecMasks.maskDigestIn("orders", pair[0]));
    }
  }

  @Test
  void aFailureShowsADigestFieldAsItsDigest()
  {
    LawSpecDataSchema.create();
    var fields = List.of(LawSpecRuntime.text("Text", "ann"), LawSpecRuntime.text("Text", IBAN),
        LawSpecRuntime.text("Text", IBAN));
    String printed =
        new LawSpecRuntime.Data("example.digest::type::Account::Account", fields).toString();
    assertFalse(printed.contains(IBAN), printed);
    assertTrue(
        printed.contains(LawSpecMasks.maskDigestIn("example.digest.Account.iban", IBAN)), printed);
  }
}
