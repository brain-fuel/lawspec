package example;
import java.math.BigInteger;
public class Algebra {
 public static Number add(BigInteger x,BigInteger y){return x.add(y);}
 public static Number multiply(BigInteger x,BigInteger y){return x.multiply(y);}
 public static Number negateValue(BigInteger x){return x.negate();}
 public static Number maximumValue(BigInteger x,BigInteger y){return x.max(y);}
 public static Number subtractValue(BigInteger x,BigInteger y){return x.subtract(y);}
 public static Number divideLeft(BigInteger x,BigInteger y){return x.subtract(y);}
 public static Number divideRight(BigInteger x,BigInteger y){return x.add(y);}
}