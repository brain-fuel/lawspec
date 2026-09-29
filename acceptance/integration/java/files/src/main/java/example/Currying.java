package example;
public class Currying {
 public static Number sumFour(java.math.BigInteger a,java.math.BigInteger b,java.math.BigInteger c,java.math.BigInteger d){return a.add(b).add(c).add(d);}
 public static String format(String prefix,boolean enabled,int port,String suffix){return prefix+(enabled?Integer.toString(port):"")+suffix;}
 public static String referenceFormat(String prefix,boolean enabled,int port,String suffix){return String.join("",prefix,enabled?String.valueOf(port):"",suffix);}
 public static String trim(String x){return x.strip();}
}