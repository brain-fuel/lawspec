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
canonPackagesVersion = "0.36.1"

-- | Each platform's tarball digest, in lowercase hexadecimal.
canonPackageDigests :: [(String, String)]
canonPackageDigests =
  [ ("darwin-arm64", "c6f3db4e361e521ea245e11b891cc3d2fa69a5fef5798edba89db2fcb291a28a"),
    ("darwin-x64", "3b671ef4d8b301733cba64392493103a36c56b00023b01e510665869eb72b591"),
    ("linux-arm64", "613d1234f57321adfdd79c0962d1ec2439cd970a24fcd9ba1c54f0ab70fa5d13"),
    ("linux-x64", "7c8c288e583c85b749fb62d68fbab9678315bda46fefe2584aa059d7960a52d0")
  ]
