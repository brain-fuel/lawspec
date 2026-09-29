package algebra
func Add(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Add(x,y)}
func Multiply(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Mul(x,y)}
func NegateValue(x *LawSpecBigInt) any {return new(LawSpecBigInt).Neg(x)}
func MaximumValue(x,y *LawSpecBigInt) any {if x.Cmp(y)>0 {return x}; return y}
func SubtractValue(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Sub(x,y)}
func DivideLeft(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Sub(x,y)}
func DivideRight(x,y *LawSpecBigInt) any {return new(LawSpecBigInt).Add(x,y)}
