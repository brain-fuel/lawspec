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
        `package example\nfun normalize(x: String): String = x.replace(" ", "-")\nfun referenceNormalize(x: String): String = x.replace(' ', '-')\n`,
        "x.replace(' ', '-')",
        "x",
      ],
      [
        "src/main/kotlin/example/CanonicalUrl.kt",
        `package example\nfun canonicalize(x: String): String = x.trimEnd('/')\n`,
        "x.trimEnd('/')",
        'x.removeSuffix("/")',
      ],
      [
        "src/main/kotlin/example/mixed/Inputs.kt",
        `package example.mixed\nfun normalize(x: String): String = x.replace(" ", "-")\nfun identity(x: Int): Int = x\n`,
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
