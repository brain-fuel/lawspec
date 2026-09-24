// [adapter path, correct source, expression to mutate, replacement]
export function textAdapters(target) {
  const data = {
    java: [
      [
        "src/main/java/example/Slug.java",
        `package example; public class Slug {
public static String normalize(String x) { return x.replace(" ", "-"); }
public static String referenceNormalize(String x) { return x.replace(' ', '-'); }
}`,
        `x.replace(' ', '-')`,
        "x",
      ],
      [
        "src/main/java/example/CanonicalUrl.java",
        `package example; public class CanonicalUrl {
public static String canonicalize(String x) { return x.replaceAll("/+$", ""); }
}`,
        '"/+$"',
        '"/$"',
      ],
      [
        "src/main/java/example/mixed/Inputs.java",
        `package example.mixed; public class Inputs {
public static String normalize(String x) { return x.replace(" ", "-"); }
public static int identity(int x) { return x; }
}`,
      ],
    ],
    python: [
      [
        "src/example/slug.py",
        `def normalize(x: str) -> str:\n    return x.replace(" ", "-")\ndef referenceNormalize(x: str) -> str:\n    return "-".join(x.split(" "))\n`,
        '"-".join(x.split(" "))',
        "x",
      ],
      [
        "src/example/canonical_url.py",
        `def canonicalize(x: str) -> str:\n    return x.rstrip("/")\n`,
        'x.rstrip("/")',
        'x.removesuffix("/")',
      ],
      [
        "src/example/mixed/inputs.py",
        `def normalize(x: str) -> str:\n    return x.replace(" ", "-")\ndef identity(x: int) -> int:\n    return x\n`,
      ],
    ],
    go: [
      [
        "example/slug/adapter.go",
        `package slug\nimport "strings"\nfunc Normalize(x string) string { return strings.ReplaceAll(x, " ", "-") }\nfunc ReferenceNormalize(x string) string { return strings.Join(strings.Split(x, " "), "-") }\n`,
        'strings.Join(strings.Split(x, " "), "-")',
        "x",
      ],
      [
        "example/canonical_url/adapter.go",
        `package canonical_url\nimport "strings"\nfunc Canonicalize(x string) string { return strings.TrimRight(x, "/") }\n`,
        'strings.TrimRight(x, "/")',
        'strings.TrimSuffix(x, "/")',
      ],
      [
        "example/mixed/inputs/adapter.go",
        `package inputs\nimport "strings"\nfunc Normalize(x string) string { return strings.ReplaceAll(x, " ", "-") }\nfunc Identity(x int32) int32 { return x }\n`,
      ],
    ],
    haskell: [
      [
        "src/Example/Slug.hs",
        `module Example.Slug where\nimport Data.Text (Text)\nimport qualified Data.Text as T\nnormalize :: Text -> Text\nnormalize = T.replace (T.pack " ") (T.pack "-")\nreferenceNormalize :: Text -> Text\nreferenceNormalize = T.map (\\c -> if c == ' ' then '-' else c)\n`,
        "T.map (\\c -> if c == ' ' then '-' else c)",
        "id",
      ],
      [
        "src/Example/CanonicalUrl.hs",
        `module Example.CanonicalUrl where\nimport Data.Text (Text)\nimport qualified Data.Text as T\ncanonicalize :: Text -> Text\ncanonicalize = T.dropWhileEnd (== '/')\n`,
        "T.dropWhileEnd (== '/')",
        "T.dropEnd 1",
      ],
      [
        "src/Example/Mixed/Inputs.hs",
        `module Example.Mixed.Inputs where\nimport Data.Text (Text)\nimport Data.Int (Int32)\nimport qualified Data.Text as T\nnormalize :: Text -> Text\nnormalize = T.replace (T.pack " ") (T.pack "-")\nidentity :: Int32 -> Int32\nidentity = id\n`,
      ],
    ],
    kotlin: [
      [
        "src/main/kotlin/example/Slug.kt",
        `package example\nobject Slug {\nfun normalize(x: String): String = x.replace(" ", "-")\nfun referenceNormalize(x: String): String = x.replace(' ', '-')\n}\n`,
        "x.replace(' ', '-')",
        "x",
      ],
      [
        "src/main/kotlin/example/CanonicalUrl.kt",
        `package example\nobject CanonicalUrl {\nfun canonicalize(x: String): String = x.trimEnd('/')\n}\n`,
        "x.trimEnd('/')",
        'x.removeSuffix("/")',
      ],
      [
        "src/main/kotlin/example/mixed/Inputs.kt",
        `package example.mixed\nobject Inputs {\nfun normalize(x: String): String = x.replace(" ", "-")\nfun identity(x: Int): Int = x\n}\n`,
      ],
    ],
  };
  if (target === "javascript" || target === "typescript") {
    const ext = target === "typescript" ? "ts" : "mjs";
    const str = target === "typescript" ? ": string" : "";
    const num = target === "typescript" ? ": number" : "";
    return [
      [
        `src/example/slug.${ext}`,
        `export const normalize = (x${str}) => x.replaceAll(" ", "-");\nexport const referenceNormalize = (x${str}) => x.split(" ").join("-");\n`,
        'x.split(" ").join("-")',
        "x",
      ],
      [
        `src/example/canonical_url.${ext}`,
        `export const canonicalize = (x${str}) => x.replace(/\\/+$/, "");\n`,
        "/\\/+$/",
        "/\\/$/",
      ],
      [
        `src/example/mixed/inputs.${ext}`,
        `export const normalize = (x${str}) => x.replaceAll(" ", "-");\nexport const identity = (x${num}) => x;\n`,
      ],
    ];
  }
  return data[target];
}

// These implementations satisfy the general law but violate the example oracle.
export function oracleMutants(target) {
  const fixtures = textAdapters(target);
  const replacements = {
    java: [
      [
        ['x.replace(" ", "-")', "x"],
        ["x.replace(' ', '-')", "x"],
      ],
      ['x.replaceAll("/+$", "")', "x.substring(0, 0)"],
    ],
    python: [
      [
        ['x.replace(" ", "-")', "x"],
        ['"-".join(x.split(" "))', "x"],
      ],
      ['x.rstrip("/")', "x[:0]"],
    ],
    go: [
      [
        ['strings.ReplaceAll(x, " ", "-")', "strings.Clone(x)"],
        ['strings.Join(strings.Split(x, " "), "-")', "strings.Clone(x)"],
      ],
      ['strings.TrimRight(x, "/")', "strings.Repeat(x, 0)"],
    ],
    haskell: [
      [
        ['T.replace (T.pack " ") (T.pack "-")', "id"],
        ["T.map (\\c -> if c == ' ' then '-' else c)", "id"],
      ],
      ["T.dropWhileEnd (== '/')", "T.take 0"],
    ],
    kotlin: [
      [
        ['x.replace(" ", "-")', "x"],
        ["x.replace(' ', '-')", "x"],
      ],
      ["x.trimEnd('/')", "x.take(0)"],
    ],
    javascript: [
      [
        ['x.replaceAll(" ", "-")', "x"],
        ['x.split(" ").join("-")', "x"],
      ],
      ['x.replace(/\\/+$/, "")', "x.slice(0, 0)"],
    ],
  };
  const [slug, canonical] =
    replacements[target === "typescript" ? "javascript" : target];
  return [slug, [canonical]].map((edits, i) => {
    let content = fixtures[i][1];
    for (const [before, after] of edits) {
      if (!content.includes(before))
        throw new Error("Missing oracle mutation marker");
      content = content.replace(before, after);
    }
    return [fixtures[i][0], content, fixtures[i][1]];
  });
}
