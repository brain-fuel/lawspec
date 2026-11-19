// User-owned LawSpec adapter.
namespace Example;

using System.Text.RegularExpressions;

public static class Vacuity
{
  /// <summary>(Text -> Text)</summary>
  public static string Shout(string name)
  {
    return name.ToUpperInvariant();
  }

  /// <summary>(example.vacuity::type::Stage -> Text)</summary>
  public static string Abbreviate(LawSpec.Data.Stage stage)
  {
    return stage.Token;
  }

  /// <summary>(example.vacuity::type::Proposal -> Bool)</summary>
  /// <remarks>Accepts only codes such as OFFER-2026-AB: no random record has one.</remarks>
  public static bool Accepts(LawSpec.Data.Proposal offer)
  {
    return Regex.IsMatch(offer.Code, "^OFFER-[0-9]{4}-[A-Z]{2}$") && offer.Amount > 0;
  }

  /// <summary>(example.vacuity::type::Proposal -> Text)</summary>
  public static string Describe(LawSpec.Data.Proposal offer)
  {
    return offer.Code;
  }

  /// <summary>(Text -> Text)</summary>
  public static string Keep(string key)
  {
    return key;
  }
}
