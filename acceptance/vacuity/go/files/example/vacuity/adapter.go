// User-owned LawSpec adapter.
package vacuity

import (
	"regexp"
	"strings"
)

var offerCode = regexp.MustCompile(`^OFFER-[0-9]{4}-[A-Z]{2}$`)

// Shout implements shout :: (Text -> Text).
func Shout(name string) string {
	return strings.ToUpper(name)
}

// Abbreviate implements abbreviate :: (example.vacuity::type::Stage -> Text).
func Abbreviate(stage Stage) string {
	return stage.Token
}

// Accepts implements accepts :: (example.vacuity::type::Proposal -> Bool).
// It accepts only codes such as OFFER-2026-AB: no random record has one.
func Accepts(offer Proposal) bool {
	return offerCode.MatchString(offer.Code) && offer.Amount > 0
}

// Describe implements describe :: (example.vacuity::type::Proposal -> Text).
func Describe(offer Proposal) string {
	return offer.Code
}

// Keep implements keep :: (Text -> Text).
func Keep(key string) string {
	return key
}
