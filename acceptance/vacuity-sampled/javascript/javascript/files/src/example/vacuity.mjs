export function shout(name){return name.toUpperCase();}
export function abbreviate(stage){return stage.token;}
export function accepts(offer){return /^OFFER-[0-9]{4}-[A-Z]{2}$/.test(offer.code)&&offer.amount>0;}
export function describe(offer){return offer.code;}
export function keep(key){return key;}
