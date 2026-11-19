# LawSpec native and resources jars

`dev.goforge:lawspec-<platform>` holds one natively compiled `lawspec`
executable, built from the LawSpec Haskell sources
(https://github.com/brain-fuel/lawspec, the `lawspec-native` executable) for
one platform, and beside it the Canon that `lawspec project` runs: the
native `canon` executable built from https://github.com/brain-fuel/canon and
Rice's Tax 0.4.3's grammar presets (https://github.com/brain-fuel/ricestax),
with `canon.json` naming the commits. `dev.goforge:lawspec-resources` holds the Learn LawSpec site
that `lawspec learn` serves, as the npm package ships it. Neither has Java
code, so their sources and javadoc jars hold only this README. The
`dev.goforge:lawspec` launcher verifies the executable against the SHA-256
in its manifest before running it, and the `canon` executable the same way.
