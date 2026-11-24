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
canonPackagesVersion = "0.36.4"

-- | Each platform's tarball digest, in lowercase hexadecimal.
canonPackageDigests :: [(String, String)]
canonPackageDigests =
  [ ("darwin-arm64", "de00535c6554a6b386e6366e52364f5022c86ff0256f292e7deb5b08099c8630"),
    ("darwin-x64", "8f52e7e9a0c6b99466c356fa611a497458c2f47cf5b858935e2990475473224c"),
    ("linux-arm64", "b7496ff154c8596436cff1904b1d8f9048be0735bf28677cce01754a760db1b8"),
    ("linux-x64", "639d940b7519308208bc76af5310633235edac8b2a706cfcb294c485297fe933")
  ]
