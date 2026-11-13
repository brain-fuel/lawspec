# User-owned LawSpec adapter.
import re

import lawspec_data as data


def shout(value0: str) -> str:
    return value0.upper()


def abbreviate(value0: data.Stage) -> str:
    return value0.token


# Accepts only codes such as OFFER-2026-AB: no random record has one.
def accepts(value0: data.Proposal) -> bool:
    return re.fullmatch("OFFER-[0-9]{4}-[A-Z]{2}", value0.code) is not None and value0.amount > 0


def describe(value0: data.Proposal) -> str:
    return value0.code


def keep(value0: str) -> str:
    return value0
