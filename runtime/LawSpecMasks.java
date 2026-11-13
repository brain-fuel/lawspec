package lawspec.runtime;

import java.nio.charset.StandardCharsets;

/**
 * The masks of a masking block, for a record's native rendering.
 *
 * <p>
 * A generated record with a masking block overrides {@code toString()} with these, so a logger or a
 * string concatenation shows what the block allows. They follow the checked definitions of the
 * built-in unit lawspec.rules (rulesMaskLast, rulesMaskEmail), which every generated test suite
 * checks; the contracts-masking acceptance suite compares the two renderings.
 *
 * <p>
 * The hash mask is keyed BLAKE3-256 (the BLAKE3 specification, section 2.1). Its key is 32 secret
 * bytes the application sets when it starts; LawSpec never writes a key into generated code and has
 * no default, so a rendering without a key throws.
 */
public final class LawSpecMasks
{
  private LawSpecMasks()
  {
  }

  /** What a hidden value shows. */
  public static final String HIDDEN = "***";

  /** Three stars and the last characters; a text no longer than that is not shown at all. */
  public static String last(int count, String value)
  {
    if (value == null)
    {
      return HIDDEN;
    }
    int length = value.codePointCount(0, value.length());
    if (length <= count)
    {
      return HIDDEN;
    }
    return HIDDEN + value.substring(value.offsetByCodePoints(0, length - count));
  }

  /**
   * The first character before the first at sign, three stars, and what follows the last at sign; a
   * text without an at sign is not shown at all.
   */
  public static String email(String value)
  {
    if (value == null)
    {
      return HIDDEN;
    }
    int first = value.indexOf('@');
    if (first < 0)
    {
      return HIDDEN;
    }
    String name = value.substring(0, first);
    String shown = name.isEmpty() ? "" : name.substring(0, name.offsetByCodePoints(0, 1));
    return shown + HIDDEN + "@" + value.substring(value.lastIndexOf('@') + 1);
  }

  private static final int[] IV = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f,
      0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  private static final int[] SCHEDULE = {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8};
  private static final int CHUNK_START = 1;
  private static final int CHUNK_END = 2;
  private static final int PARENT = 4;
  private static final int ROOT = 8;
  private static final int KEYED_HASH = 16;

  private static volatile int[] hashKey;

  /**
   * Sets the key of the hash mask: 32 secret bytes the application loads when it starts.
   *
   * @throws IllegalArgumentException when the key is not 32 bytes
   */
  public static void setHashKey(byte[] key)
  {
    if (key == null || key.length != 32)
    {
      throw new IllegalArgumentException("LawSpec masking: the hash key is 32 bytes");
    }
    int[] words = new int[8];
    System.arraycopy(words(key, 0, 32), 0, words, 0, 8);
    hashKey = words;
  }

  /**
   * The word hash, a colon and the keyed BLAKE3-256 digest of the text's UTF-8 bytes: equal values
   * show alike, and the value cannot be read back without the key.
   *
   * @throws IllegalStateException when no key is set; it never falls back to showing or hiding
   */
  public static String hash(String value)
  {
    int[] key = hashKey;
    if (key == null)
    {
      throw new IllegalStateException(
          "LawSpec masking: a field is shown as hash and no key is set; call"
              + " LawSpecMasks.setHashKey with 32 secret bytes when the application starts");
    }
    byte[] bytes = String.valueOf(value).getBytes(StandardCharsets.UTF_8);
    int chunks = Math.max(1, (bytes.length + 1023) / 1024);
    // The reference implementation's merge: a stack of subtree chaining values, one subtree
    // closed per trailing zero of the chunk count.
    int[][] stack = new int[32][];
    int depth = 0;
    for (int index = 0; index < chunks - 1; index++)
    {
      int[] cv = chunk(key, bytes, index, 0);
      for (int total = index + 1; total % 2 == 0; total /= 2)
      {
        depth--;
        cv = compress(key, join(stack[depth], cv), 0, 64, KEYED_HASH | PARENT);
      }
      stack[depth] = cv;
      depth++;
    }
    int[] root;
    if (depth == 0)
    {
      root = chunk(key, bytes, chunks - 1, ROOT);
    }
    else
    {
      int[] cv = chunk(key, bytes, chunks - 1, 0);
      while (depth > 1)
      {
        depth--;
        cv = compress(key, join(stack[depth], cv), 0, 64, KEYED_HASH | PARENT);
      }
      root = compress(key, join(stack[0], cv), 0, 64, KEYED_HASH | PARENT | ROOT);
    }
    StringBuilder hex = new StringBuilder("hash:");
    for (int word : root)
    {
      for (int shift = 0; shift < 32; shift += 8)
      {
        int octet = (word >>> shift) & 255;
        hex.append(Character.forDigit(octet >>> 4, 16)).append(Character.forDigit(octet & 15, 16));
      }
    }
    return hex.toString();
  }

  /** A chunk's chaining value; its last block carries the extra flags. */
  private static int[] chunk(int[] key, byte[] bytes, int index, int last)
  {
    int end = Math.min(bytes.length, index * 1024 + 1024);
    int offset = index * 1024;
    int[] cv = key;
    int flags = KEYED_HASH | CHUNK_START;
    while (end - offset > 64)
    {
      cv = compress(cv, words(bytes, offset, 64), index, 64, flags);
      flags = KEYED_HASH;
      offset += 64;
    }
    return compress(cv, words(bytes, offset, end - offset), index, end - offset,
        flags | CHUNK_END | last);
  }

  private static int[] join(int[] left, int[] right)
  {
    int[] words = new int[16];
    System.arraycopy(left, 0, words, 0, 8);
    System.arraycopy(right, 0, words, 8, 8);
    return words;
  }

  /** Sixteen little-endian words of a block, zero padded past its length. */
  private static int[] words(byte[] bytes, int offset, int length)
  {
    int[] words = new int[16];
    for (int i = 0; i < length; i++)
    {
      words[i >>> 2] |= (bytes[offset + i] & 255) << (8 * (i & 3));
    }
    return words;
  }

  /** The first eight words of BLAKE3's compression: a chaining value. */
  private static int[] compress(int[] cv, int[] block, long counter, int length, int flags)
  {
    int[] state = new int[16];
    System.arraycopy(cv, 0, state, 0, 8);
    System.arraycopy(IV, 0, state, 8, 4);
    state[12] = (int) counter;
    state[13] = (int) (counter >>> 32);
    state[14] = length;
    state[15] = flags;
    int[] m = block;
    for (int round = 0; round < 7; round++)
    {
      mix(state, 0, 4, 8, 12, m[0], m[1]);
      mix(state, 1, 5, 9, 13, m[2], m[3]);
      mix(state, 2, 6, 10, 14, m[4], m[5]);
      mix(state, 3, 7, 11, 15, m[6], m[7]);
      mix(state, 0, 5, 10, 15, m[8], m[9]);
      mix(state, 1, 6, 11, 12, m[10], m[11]);
      mix(state, 2, 7, 8, 13, m[12], m[13]);
      mix(state, 3, 4, 9, 14, m[14], m[15]);
      int[] next = new int[16];
      for (int i = 0; i < 16; i++)
      {
        next[i] = m[SCHEDULE[i]];
      }
      m = next;
    }
    int[] out = new int[8];
    for (int i = 0; i < 8; i++)
    {
      out[i] = state[i] ^ state[i + 8];
    }
    return out;
  }

  private static void mix(int[] state, int a, int b, int c, int d, int x, int y)
  {
    state[a] = state[a] + state[b] + x;
    state[d] = Integer.rotateRight(state[d] ^ state[a], 16);
    state[c] = state[c] + state[d];
    state[b] = Integer.rotateRight(state[b] ^ state[c], 12);
    state[a] = state[a] + state[b] + y;
    state[d] = Integer.rotateRight(state[d] ^ state[a], 8);
    state[c] = state[c] + state[d];
    state[b] = Integer.rotateRight(state[b] ^ state[c], 7);
  }
}
