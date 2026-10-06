# User-owned LawSpec adapter: pause notes when it is called.
import os
import time


def _note(event, n):
    path = os.environ.get("LAWSPEC_SCHEDULE_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as log:
            log.write(f"{event} {n} {time.time() * 1000:.3f}\n")


# LawSpec argument 0: Int32
# LawSpec result: Bool
def pause(value0: int) -> bool:
    _note("start", value0)
    time.sleep(0.005)
    _note("end", value0)
    return True
