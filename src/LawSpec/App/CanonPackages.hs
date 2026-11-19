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
canonPackagesVersion = "0.36.0"

-- | Each platform's tarball digest, in lowercase hexadecimal.
canonPackageDigests :: [(String, String)]
canonPackageDigests =
  [ ("darwin-arm64", "cba960363dc966664c0890191a8b5eac6ee3b94401aaaf7040982243d91d5cb1"),
    ("darwin-x64", "341ac28fe6eb262211292883bcb10003b36e5aefb179dfb0299bd5225bf4ba7a"),
    ("linux-arm64", "16566614ebd1f56aefdb3b65c63e972be4768a22290d43e5152073f34c632170"),
    ("linux-x64", "70029ba60bfd50855592485ab1364a2fb4d246a14950dc19b1312e9077699425")
  ]
