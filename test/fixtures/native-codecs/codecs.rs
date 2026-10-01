use crate::{domain, lawspec_data as data, lawspec_runtime as ls};

pub fn to_parcel<T, N>(
    value: data::Parcel<T>,
    convert: &dyn Fn(T) -> N,
) -> ls::Result<domain::Parcel<N>> {
    let data::Parcel { item } = value;
    Ok(domain::Parcel::new(convert(item)))
}

pub fn from_parcel<T, N>(
    value: domain::Parcel<N>,
    convert: &dyn Fn(N) -> T,
) -> ls::Result<data::Parcel<T>> {
    Ok(data::Parcel {
        item: convert(value.into_inner()),
    })
}

pub fn to_chain<T, N>(
    mut value: data::Chain<T>,
    convert: &dyn Fn(T) -> N,
) -> ls::Result<domain::FlatChain<N>> {
    let mut items = Vec::new();
    loop {
        match value {
            data::Chain::Stop => return Ok(domain::FlatChain::new(items, true)),
            data::Chain::More { item, tail } => {
                items.push(convert(item));
                match tail {
                    None => return Ok(domain::FlatChain::new(items, false)),
                    Some(next) => value = *next,
                }
            }
        }
    }
}

pub fn from_chain<T, N>(
    value: domain::FlatChain<N>,
    convert: &dyn Fn(N) -> T,
) -> ls::Result<data::Chain<T>> {
    let (items, explicit_stop) = value.into_parts();
    let mut tail = if explicit_stop {
        Some(Box::new(data::Chain::Stop))
    } else {
        None
    };
    for item in items.into_iter().rev() {
        tail = Some(Box::new(data::Chain::More {
            item: convert(item),
            tail,
        }));
    }
    tail.map(|value| *value)
        .ok_or_else(|| "empty chain without Stop has no logical representation".into())
}

pub fn to_positive(value: data::Positive) -> ls::Result<domain::Positive> {
    let data::Positive { value } = value;
    Ok(domain::Positive::new(value))
}

pub fn from_positive(value: domain::Positive) -> ls::Result<data::Positive> {
    Ok(data::Positive {
        value: value.into_inner(),
    })
}
