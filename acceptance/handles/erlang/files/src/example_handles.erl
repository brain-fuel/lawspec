%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(example_handles).
-export([new_jobs/1,submit/2,take/1,pending/1]).
new_jobs(ok) -> beam_jobs:new().
submit(Jobs,Value) -> true=beam_jobs:submit(Jobs,Value), ok.
take(Jobs) -> beam_jobs:take(Jobs).
pending(Jobs) -> beam_jobs:pending(Jobs).
