-- | The receipts of the capability laws' proofs. Written by
-- lawspec-dev capability-receipts; do not edit. ref:DEC-capability-laws
module LawSpec.CapabilityReceipts (capabilityReceipts, capabilityReceiptsProver) where

-- | The solver that proved them.
capabilityReceiptsProver :: String
capabilityReceiptsProver = "Z3 version 5.1.0 - 64 bit"

-- | Each proved law, and what its proof was of (LawSpec.ProofSettings.capabilityLawKey).
capabilityReceipts :: [(String, String)]
capabilityReceipts =
  [ ("lawspec.instances.laws::law::|map of the identity changes nothing|","1c6be805a1a469b30904c8b80d9ea3a21e32d0bbf92d087ea3d4b16f01f9c039")
  , ("lawspec.instances.laws::law::|map of a composition is two maps|","0a1599f1433f7ba4cee18830ef7c9aa454d71282bd9aeeaf37a550e09d354e74")
  , ("lawspec.instances.laws::law::|map over an Either of the identity changes nothing|","7b416fd198c745871722fb7233f58b28a1d02ed60b4d9cabb2df65425ab374b6")
  , ("lawspec.instances.laws::law::|map over an Either of a composition is two maps|","090e88d536825068e21dc15e8c6ac375798780271990e960e890f84b62ffdcac")
  , ("lawspec.instances.laws::law::|filter keeps only what is accepted|","e4f8a6ea66cae45c7d3cbd5f95feb8c321a6ea8f3016472a3f19776b37321b1e")
  , ("lawspec.instances.laws::law::|filter never lengthens|","92ac22c2705f3b85c4fa41b548c0cefe7d1ff78d8c15074e4e5babc168ba015f")
  , ("lawspec.instances.laws::law::|filters commute|","d016420e8e8e39d52d5f6621d4b28bd1894972953d80021da523a8f6532f788d")
  , ("lawspec.instances.laws::law::|filter of what is all accepted changes nothing|","d1cfe3d0bcc2b08f3ee0dc34cd7116cb167bf932893e192184f3745efb54f58a")
  , ("lawspec.instances.laws::law::|length is never negative|","83e4ff31a9d632becf50f8ff8ff633463f8926654d463cff2589feb89708701c")
  , ("lawspec.instances.laws::law::|all and any are dual|","7e68025f9fe865092ca1cfcaa2f9aadf61ae1518291d03cba685c91d17c91135")
  , ("lawspec.instances.laws::law::|appending nothing changes nothing|","aeff9e65131906fb8ce96ba282d913467929e5a51b5493f42c0aef4e81b2ad9e")
  , ("lawspec.instances.laws::law::|append associates|","27a8dc7bda5869a1084d60462f949473a3fb634e669a44ddedbe349ec0bd164a")
  , ("lawspec.instances.laws::law::|length of an append is the sum|","7f7c6f9371fe4469c8300b2a9037a311bd36e51b8300ee41f01a28df5a762503")
  , ("lawspec.instances.laws::law::|map keeps the length|","ca056562d2b8aa38a97c341fd3bcb766a96ae9dcf6d1a6165136d7d224027d86")
  , ("lawspec.instances.laws::law::|map distributes over append|","1758e476b5d75a8078cd37d93829b8c73036425f7dfe8d3d3c7320f50b4adb9c")
  , ("lawspec.instances.laws::law::|filter distributes over append|","95e0614c2492ceadcbaca01ec191f0b3371348274470807e1aef7ae79d2617bc")
  , ("lawspec.instances.laws::law::|all of an append is all of both|","c32d7901f8d0f5405083516d5ec88bbd257f9b1c4fcce099a881c0f8221f942b")
  , ("lawspec.instances.laws::law::|a right fold of an append folds the second first|","bf09f33ee239c1950539b92c35f4ad6a6b6b7f0948797ec581cd044ad1767d17")
  , ("lawspec.instances.laws::law::|a left fold of an append folds the first first|","581cf00963c5cecba6686011a6dc4f855ee65c7c0c09c3a21834777343ae7d78")
  , ("lawspec.instances.laws::law::|filter after map is map after filter|","d4df74aa2aaedd6fda6694f3dcdb5a4bfe1839df35a2d351804e1ea9f7c73ef3")
  ]
