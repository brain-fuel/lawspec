// Configured Eclipse JDT formatting; no bespoke source rewriting.
// ref:DEC-google-style-allman
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.HashMap;
import javax.xml.parsers.DocumentBuilderFactory;
import org.eclipse.jdt.core.ToolFactory;
import org.eclipse.jdt.core.dom.AST;
import org.eclipse.jdt.core.dom.ASTParser;
import org.eclipse.jdt.core.dom.CompilationUnit;
import org.eclipse.jdt.core.formatter.CodeFormatter;
import org.eclipse.jface.text.Document;

public final class JavaCodeStyle
{
  public static void main(String[] args) throws Exception
  {
    var settings = new HashMap<String, String>();
    var factory = DocumentBuilderFactory.newInstance();
    factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
    var profile = factory.newDocumentBuilder().parse(args[0]);
    var nodes = profile.getElementsByTagName("setting");
    for (int index = 0; index < nodes.getLength(); index++)
    {
      var attributes = nodes.item(index).getAttributes();
      settings.put(attributes.getNamedItem("id").getNodeValue(),
          attributes.getNamedItem("value").getNodeValue());
    }
    var formatter = ToolFactory.createCodeFormatter(settings);
    for (int index = 1; index < args.length; index++)
    {
      var path = Path.of(args[index]);
      var source = Files.readString(path);
      var parser = ASTParser.newParser(AST.getJLSLatest());
      parser.setKind(ASTParser.K_COMPILATION_UNIT);
      parser.setSource(source.toCharArray());
      parser.setCompilerOptions(settings);
      var parsed = (CompilationUnit) parser.createAST(null);
      if (Arrays.stream(parsed.getProblems()).anyMatch(problem -> problem.isError()))
      {
        throw new IllegalArgumentException(
            "Java syntax errors; render templates before formatting: " + path);
      }
      var edit =
          formatter.format(CodeFormatter.K_COMPILATION_UNIT | CodeFormatter.F_INCLUDE_COMMENTS,
              source, 0, source.length(), 0, "\n");
      if (edit == null)
      {
        throw new IllegalArgumentException("Cannot format Java source: " + path);
      }
      var document = new Document(source);
      edit.apply(document);
      Files.writeString(path, document.get());
    }
  }
}
