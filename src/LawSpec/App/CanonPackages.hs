-- | The SHA-256 of each @goforgedev/canon-<platform> npm tarball
-- (tools/package-canon.sh) for this LawSpec release, which a host that ships
-- no Canon of its own (the Go host) has the core download and verify
-- ("LawSpec.App.CanonDownload"). The owner publishes those tarballs as they
-- are packed, so these are the registry's bytes. An empty digest is not
-- recorded yet, and the core then refuses to download that platform's
-- Canon rather than run bytes it cannot check.
--
-- lawspec-dev canon-packages --record writes this file from the tarballs in
-- .artifacts/canon-npm, and integrity checks any tarball found there
-- against it. Only those two edit it.
-- ref:DEC-native-canon
module LawSpec.App.CanonPackages
  ( canonPackagesVersion,
    canonPackageDigests,
  )
where

-- | The LawSpec version the tarballs below were packed for.
canonPackagesVersion :: String
canonPackagesVersion = "0.36.3"

-- | Each platform's tarball digest, in lowercase hexadecimal.
canonPackageDigests :: [(String, String)]
canonPackageDigests =
  [ ("darwin-arm64", "39d3258eaf717290f124bda97d9c21fc25abd4cfe0f1268258d650bdca036fb1"),
    ("darwin-x64", "f2251355a9471f4e18a8745640a88cc6bf99ed89e932e71a099972a0069037b6"),
    ("linux-arm64", "131fbc3b39cdbd908dfb0818773f782e6e4256db1e8cf8b3fc220c513182cb06"),
    ("linux-x64", "6f888a9cc49651897e6bcd1efbfc5c9b4e1fe15ea577c5da752fd550988dd676")
  ]
