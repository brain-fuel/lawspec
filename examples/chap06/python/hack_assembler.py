"""Translate valid Hack assembly programs to physical sixteen-bit output lines."""

PREDEFINED = {
    **{f"R{index}": index for index in range(16)},
    "SP": 0,
    "LCL": 1,
    "ARG": 2,
    "THIS": 3,
    "THAT": 4,
    "SCREEN": 16384,
    "KBD": 24576,
}

COMPUTATIONS = {
    "0": 0b0101010,
    "1": 0b0111111,
    "-1": 0b0111010,
    "D": 0b0001100,
    "A": 0b0110000,
    "M": 0b1110000,
    "!D": 0b0001101,
    "!A": 0b0110001,
    "!M": 0b1110001,
    "-D": 0b0001111,
    "-A": 0b0110011,
    "-M": 0b1110011,
    "D+1": 0b0011111,
    "A+1": 0b0110111,
    "M+1": 0b1110111,
    "D-1": 0b0001110,
    "A-1": 0b0110010,
    "M-1": 0b1110010,
    "D+A": 0b0000010,
    "D+M": 0b1000010,
    "D-A": 0b0010011,
    "D-M": 0b1010011,
    "A-D": 0b0000111,
    "M-D": 0b1000111,
    "D&A": 0b0000000,
    "D&M": 0b1000000,
    "D|A": 0b0010101,
    "D|M": 0b1010101,
}

JUMPS = {"": 0, "JGT": 1, "JEQ": 2, "JGE": 3, "JLT": 4, "JNE": 5, "JLE": 6, "JMP": 7}
DESTINATIONS = {"A": 4, "D": 2, "M": 1}


def assemble(source: str) -> list[str]:
    symbols = dict(PREDEFINED)
    instructions = []
    for physical in source.splitlines():
        instruction = "".join(physical.partition("//")[0].split())
        if not instruction:
            continue
        if instruction.startswith("(") and instruction.endswith(")"):
            symbols[instruction[1:-1]] = len(instructions)
        else:
            instructions.append(instruction)

    next_variable = 16
    output = []
    for instruction in instructions:
        if instruction.startswith("@"):
            operand = instruction[1:]
            if operand.isdecimal():
                address = int(operand, 10)
            else:
                if operand not in symbols:
                    symbols[operand] = next_variable
                    next_variable += 1
                address = symbols[operand]
            if not 0 <= address <= 32767:
                raise ValueError("A-instruction address must fit fifteen bits")
            output.append(f"{address:016b}")
        else:
            before_jump, separator, jump = instruction.partition(";")
            destination, assignment, computation = before_jump.partition("=")
            if not assignment:
                destination, computation = "", destination
            comp = COMPUTATIONS[computation]
            dest = sum(DESTINATIONS[register] for register in destination)
            word = 0xE000 | (comp << 6) | (dest << 3) | JUMPS[jump if separator else ""]
            output.append(f"{word:016b}")
    return output


if __name__ == "__main__":
    import argparse
    from pathlib import Path

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    arguments = parser.parse_args()
    lines = assemble(arguments.source.read_text(encoding="utf-8"))
    arguments.source.with_suffix(".hack").write_text(
        "\n".join(lines) + ("\n" if lines else ""), encoding="ascii"
    )
