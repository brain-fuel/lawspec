module Example.Gadt (describe) where
import qualified Data.Text as T
import qualified LawSpecData as D
describe :: D.Shown -> T.Text
describe (D.Shown _ witness) = witness
