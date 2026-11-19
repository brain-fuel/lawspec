{-# LANGUAGE GADTs #-}

-- | lawspec learn in the Haskell application port, over the in-memory host
-- with scripted connections: the requests a listener receives, in order,
-- and the listener closing once they run out, which ends the server. The
-- expected statuses, headers and bodies are learn.mjs's; the URL handling
-- is checked against what Node's URL and decodeURIComponent give, and
-- tools/host-parity.mjs compares whole sessions with the legacy server
-- over loopback.
-- ref:DEC-haskell-application-port ref:DEC-host-effect-abi
module LearnSpec (spec) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.Map.Strict as M
import LawSpec.App.Learn (decodeComponent, extensionOf, urlPathname)
import LawSpec.App.Main
import LawSpec.Host.Effect
import LawSpec.Host.Fake
import Test.Hspec

-- | The package resources: the site, its compiler glue, core.wasm and its
-- gzipped copy, whose trailer records core.wasm's four bytes.
package :: World
package =
  foldr
    (uncurry withFile)
    emptyWorld
    [ ("/pkg/learn/index.html", BC.pack "<!doctype html>"),
      ("/pkg/learn/style.css", BC.pack "body{}"),
      ("/pkg/learn/app.mjs", BC.pack "export {};"),
      ("/pkg/learn/sandbox-frame.html", BC.pack "<!doctype html>"),
      ("/pkg/learn/vendor/manifest.json", BC.pack "{}\n"),
      ("/pkg/learn/vendor/font.woff2", BC.pack "wOF2"),
      ("/pkg/learn/notes.txt", BC.pack "notes"),
      ("/pkg/core_jsffi.js", BC.pack "export default {};"),
      ("/pkg/core.wasm", BC.pack "\0asm"),
      ("/pkg/core.wasm.gz", gzipped 4),
      ("/pkg/package.json", BC.pack "{}"),
      ("/p/lawspec.edn", BC.pack "{}")
    ]

-- | Bytes shaped as a gzip member whose trailer records the given length.
gzipped :: Int -> B.ByteString
gzipped size = B.replicate 14 0x1f <> B.pack [fromIntegral size, 0, 0, 0]

withLink :: FilePath -> FilePath -> World -> World
withLink path destination world = world {worldFiles = M.insert path (LinkNode destination) (worldFiles world)}

request :: Int -> String -> String -> IncomingRequest
request number method path = IncomingRequest (RequestId number) method path [("host", "127.0.0.1")] B.empty

-- | Run lawspec learn with the package's resources and these connections;
-- the listener closes once they have been accepted.
learn :: [String] -> Maybe FilePath -> [IncomingRequest] -> World -> (Outcome, World)
learn arguments resources requests world =
  runFake
    (lawspecMain fakeHost pureCompiler (Invocation ("learn" : arguments) "/p" Nothing Nothing resources Nothing))
    world {worldRequests = requests, worldHangUp = True}

-- | The ports the command asked to listen on.
servedPorts :: World -> [Int]
servedPorts world = concatMap portOf (worldTrace world)
  where
    portOf :: SomeEffect -> [Int]
    portOf (SomeEffect effect) = portIn effect
    portIn :: Effect a -> [Int]
    portIn = \case
      Serve port -> [port]
      _ -> []

stdout', stderr' :: World -> String
stdout' = BC.unpack . worldStdout
stderr' = BC.unpack . worldStderr

-- | The answers, by request number: status, headers and body.
answers :: World -> [(Int, (Int, [(String, String)], String))]
answers world = [(number, (responseStatus r, responseHeaders r, BC.unpack (responseBody r))) | (RequestId number, r) <- worldAnswers world]

served :: String -> String -> (Int, [(String, String)], String)
served kind body = (200, [("Content-Type", kind), ("X-Content-Type-Options", "nosniff"), ("Cache-Control", "no-cache")], body)

notFound :: (Int, [(String, String)], String)
notFound = (404, [], "Not found")

spec :: Spec
spec = describe "the application port of lawspec learn" $ do
  it "parses request targets as Node's URL does against http://localhost" $
    map
      (\target -> (target, urlPathname target))
      [ "/a/../b",
        "/%2e%2E/x",
        "/a\\b",
        "//foo/bar",
        "/a?b#c",
        "http://x/y",
        "/x/%2e",
        "/x/%2e%2e",
        "?q",
        "a/b",
        "/a%2Fb",
        "\\\\h/x",
        "/.%2e/z",
        "/x/..",
        "//",
        "///x",
        "//a b/x",
        "//:80/x",
        "//@/x",
        "//a:b/x",
        "//a%20b/x",
        "//[::1]/x",
        "//a@b/x",
        "//1.2.3.4/x",
        "//1.2.3.256/x",
        "//h:65536/x",
        "//09/x",
        "//0x1g/x",
        "x:index.html",
        "file:///etc/x"
      ]
      `shouldBe` [ ("/a/../b", Just "/b"),
                   ("/%2e%2E/x", Just "/x"),
                   ("/a\\b", Just "/a/b"),
                   ("//foo/bar", Just "/bar"),
                   ("/a?b#c", Just "/a"),
                   ("http://x/y", Just "/y"),
                   ("/x/%2e", Just "/x/"),
                   ("/x/%2e%2e", Just "/"),
                   ("?q", Just "/"),
                   ("a/b", Just "/a/b"),
                   ("/a%2Fb", Just "/a%2Fb"),
                   ("\\\\h/x", Just "/x"),
                   ("/.%2e/z", Just "/z"),
                   ("/x/..", Just "/"),
                   ("//", Nothing),
                   ("///x", Just "/"),
                   ("//a b/x", Nothing),
                   ("//:80/x", Nothing),
                   ("//@/x", Nothing),
                   ("//a:b/x", Nothing),
                   ("//a%20b/x", Nothing),
                   ("//[::1]/x", Just "/x"),
                   ("//a@b/x", Just "/x"),
                   ("//1.2.3.4/x", Just "/x"),
                   ("//1.2.3.256/x", Nothing),
                   ("//h:65536/x", Nothing),
                   ("//09/x", Nothing),
                   ("//0x1g/x", Just "/x"),
                   ("x:index.html", Just "index.html"),
                   ("file:///etc/x", Just "/etc/x")
                 ]
  it "decodes percent escapes as decodeURIComponent does" $
    map decodeComponent ["/a%2Fb", "%41%42", "%C3%BC", "%F0%9F%98%80", "%", "%zz", "%C3", "%C3%41", "%C0%80", "%ED%A0%80", "%F4%90%80%80", "%FF", "\195\188"]
      `shouldBe` [Just "/a/b", Just "AB", Just "\252", Just "\128512", Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Just "\195\188"]
  it "takes a file's extension as path.extname does" $
    map extensionOf ["/r/a.html", "/r/.html", "/r/..html", "/r/a.", "/r/..", "/r/a..b", "/r/.a.b", "/r/x.y/index", "/r/..."]
      `shouldBe` [".html", "", ".html", ".", "", ".b", ".b", "", "."]
  it "serves the site, the compiler and its glue, and refuses the rest" $ do
    let world' =
          withLink "/pkg/learn/inside.htm" "index.html" $
            withLink "/pkg/learn/outside.html" "../package.json" package
        requests =
          zipWith
            (\number (method, path) -> request number method path)
            [1 ..]
            [ ("GET", "/"),
              ("HEAD", "/"),
              ("GET", "/index.html?x=1"),
              ("GET", "/style.css"),
              ("GET", "/app.mjs"),
              ("GET", "/vendor/manifest.json"),
              ("GET", "/vendor/font.woff2"),
              ("GET", "/notes.txt"),
              ("GET", "/core_jsffi.js"),
              ("GET", "/core.wasm.gz"),
              ("HEAD", "/core.wasm.gz"),
              ("GET", "/x%2F..%2Findex.html"),
              ("GET", "/%2e%2e%2fpackage.json"),
              ("GET", "/../package.json"),
              ("GET", "/vendor"),
              ("GET", "/vendor/"),
              ("GET", "/missing"),
              ("GET", "/%zz"),
              ("GET", "/inside.htm"),
              ("GET", "/outside.html"),
              ("GET", "/a%00b"),
              ("POST", "/"),
              ("PUT", "/index.html")
            ]
        (outcome, world) = learn ["--port", "0"] (Just "/pkg") requests world'
        html = served "text/html; charset=utf-8" "<!doctype html>"
        gzip body = (200, [("Content-Type", "application/gzip"), ("Cache-Control", "no-cache")], body)
    stdout' world `shouldBe` "Learn LawSpec: http://127.0.0.1:40001/\n"
    (outcome, stderr' world) `shouldBe` (Completed 1, "lawspec: the listener closed\n")
    answers world
      `shouldBe` zip
        [1 ..]
        [ html,
          served "text/html; charset=utf-8" "",
          html,
          served "text/css; charset=utf-8" "body{}",
          served "text/javascript; charset=utf-8" "export {};",
          served "application/json; charset=utf-8" "{}\n",
          served "font/woff2" "wOF2",
          served "application/octet-stream" "notes",
          served "text/javascript; charset=utf-8" "export default {};",
          gzip (BC.unpack (gzipped 4)),
          gzip "",
          html,
          notFound,
          notFound,
          notFound,
          notFound,
          notFound,
          notFound,
          -- A link inside the site is served by the type of the file it
          -- names.
          html,
          notFound,
          notFound,
          (405, [], ""),
          (405, [], "")
        ]
  it "listens on 8384 unless --port names another port" $ do
    let (_, world) = learn [] (Just "/pkg") [] package
    stdout' world `shouldBe` "Learn LawSpec: http://127.0.0.1:8384/\n"
    servedPorts world `shouldBe` [8384]
  it "fails as learn.mjs does before listening" $ do
    let failure arguments resources world =
          let (outcome, ran) = learn arguments resources [] world
           in (outcome, stdout' ran, stderr' ran, map (const ()) (servedPorts ran))
        missing = "lawspec: Learn assets are missing. In a compiler checkout run npm ci --prefix learn, make generate, and npm run build --prefix learn.\n"
        port = "lawspec: --port must be an integer from 1 to 65535 (0 selects an available port)\n"
    failure [] Nothing package `shouldBe` (Completed 1, "", missing, [])
    failure [] (Just "/pkg") package {worldFiles = M.delete "/pkg/learn/vendor/manifest.json" (worldFiles package)} `shouldBe` (Completed 1, "", missing, [])
    failure [] (Just "/pkg") package {worldFiles = M.delete "/pkg/learn/sandbox-frame.html" (worldFiles package)} `shouldBe` (Completed 1, "", missing, [])
    mapM_
      (\value -> failure ["--port", value] (Just "/pkg") package `shouldBe` (Completed 1, "", port, []))
      ["x", "-1", "65536", "1.5", "0x10", " 80", "\1636"]
    failure ["--port", "08384"] (Just "/pkg") package {worldPorts = [8384]}
      `shouldBe` (Completed 1, "", "lawspec: listen EADDRINUSE: address already in use 127.0.0.1:8384\n", [()])
    failure ["--json"] (Just "/pkg") package `shouldBe` (Completed 1, "{\n  \"diagnostics\": [\n    {\n      \"code\": \"cli\",\n      \"message\": \"Usage: lawspec learn [--port <port>]\",\n      \"at\": null\n    }\n  ]\n}\n", "", [])
    failure ["--strict"] (Just "/pkg") package `shouldBe` (Completed 1, "", "lawspec: --strict applies to advise\n", [])
  it "serves the gzipped compiler only while it matches core.wasm" $ do
    let without = package {worldFiles = M.delete "/pkg/core.wasm.gz" (worldFiles package)}
        (outcome, world) = learn [] (Just "/pkg") [] without
    (outcome, stderr' world)
      `shouldBe` (Completed 1, "lawspec: Learn's compiler archive /pkg/core.wasm.gz is missing or older than core.wasm. In a compiler checkout run node tools/learn-build.mjs.\n")
    let stale = withFile "/pkg/core.wasm.gz" (gzipped 5) package
        (_, served') = learn [] (Just "/pkg") [request 1 "GET" "/core.wasm.gz", request 2 "HEAD" "/core.wasm.gz"] stale
    answers served' `shouldBe` [(1, notFound), (2, (200, [("Content-Type", "application/gzip"), ("Cache-Control", "no-cache")], ""))]
    stderr' served'
      `shouldBe` "lawspec: Learn's compiler archive /pkg/core.wasm.gz is missing or older than core.wasm. In a compiler checkout run node tools/learn-build.mjs.\nlawspec: the listener closed\n"
  it "reads only the package's resources and listens on loopback alone" $ do
    let (_, world) = learn ["--port", "0"] (Just "/pkg") [request 1 "GET" "/%2e%2e%2fpackage.json"] package
        touched = [path | SomeEffect effect <- worldTrace world, Just path <- [pathOf effect]]
        pathOf :: Effect a -> Maybe FilePath
        pathOf = \case
          ReadFile path -> Just path
          Stat _ path -> Just path
          RealPath path -> Just path
          _ -> Nothing
    filter (`notElem` ["/pkg/learn", "/pkg/learn/vendor/manifest.json", "/pkg/learn/sandbox-frame.html", "/pkg/core.wasm", "/pkg/core.wasm.gz", "/pkg/package.json"]) touched `shouldBe` []
    worldFiles world `shouldBe` worldFiles package
