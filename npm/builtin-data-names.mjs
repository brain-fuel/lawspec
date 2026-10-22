// Generated from templates/npm/builtin-data-names.mjs by lawspec-dev generate. Do not edit.
// Names and field order projected from the compiler's primitive data registry.
// This is presentation metadata, not another type checker or public wire view.
export const builtinDataNames =
[
  {
    "id": "List",
    "name": "List",
    "constructors": [
      {
        "id": "List::Nil",
        "name": "Nil",
        "fields": []
      },
      {
        "id": "List::Cons",
        "name": "Cons",
        "fields": [
          {
            "name": "head"
          },
          {
            "name": "tail"
          }
        ]
      }
    ]
  },
  {
    "id": "Maybe",
    "name": "Maybe",
    "constructors": [
      {
        "id": "Maybe::Absent",
        "name": "Absent",
        "fields": []
      },
      {
        "id": "Maybe::Present",
        "name": "Present",
        "fields": [
          {
            "name": "value"
          }
        ]
      }
    ]
  },
  {
    "id": "Either",
    "name": "Either",
    "constructors": [
      {
        "id": "Either::Left",
        "name": "Left",
        "fields": [
          {
            "name": "value"
          }
        ]
      },
      {
        "id": "Either::Right",
        "name": "Right",
        "fields": [
          {
            "name": "value"
          }
        ]
      }
    ]
  }
];
