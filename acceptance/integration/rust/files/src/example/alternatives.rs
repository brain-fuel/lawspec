#![allow(non_snake_case)]
pub fn render(x:i32)->String {x.to_string()}
pub fn referenceRender(x:i32)->String {format!("{x}")}
pub fn clamp(x:i32)->i32 {x.max(0)}
pub fn referenceClamp(x:i32)->i32 {if x<0 {0} else {x}}
