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
canonPackagesVersion = "0.36.2"

-- | Each platform's tarball digest, in lowercase hexadecimal.
canonPackageDigests :: [(String, String)]
canonPackageDigests =
  [ ("darwin-arm64", "3fb559eca008cffdd30ef10ffdcdb2d1c687d5d9dde2a6ff0af2acd846626255"),
    ("darwin-x64", "a22a3ce692ba475d83f761e8646aa1e300b1e583f530f306307fd545dabf117f"),
    ("linux-arm64", "36e0db62ab9b08916c5cd57077ee7ff105c63e05e44ed54233983be512fe2d72"),
    ("linux-x64", "0e1badde8ad78e996a6dfaca2ace8572670996673c1e8c27c92169c1e507f12c")
  ]
