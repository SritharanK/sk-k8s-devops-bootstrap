---
# status: proposed | accepted | rejected | deprecated | superseded by ADR-NNNN
status: proposed
# date: the day the status last changed, YYYY-MM-DD
date: YYYY-MM-DD
decision-makers: platform maintainers
---

# {Short title that names the problem and the chosen solution}

{One or two sentences: what this record decides and who it is for.}

## Context and problem statement

{Describe the situation in two to five sentences: what exists, what constrains the choice, and what goes wrong without a decision. End with the problem as a question.}

## Decision drivers

- {Driver, for example a quality goal, a constraint or a risk}
- {Driver}
- {Driver}

## Considered options

- {Option 1}
- {Option 2}
- {Option 3}

## Decision outcome

Chosen option: "{Option 1}", because {justification: the drivers it meets that the other options do not}.

{Optional: how the decision is implemented, with the paths, values keys, Make targets and CI jobs involved.}

### Consequences

- Good, because {positive consequence}
- Bad, because {negative consequence, stated as concretely as the positive ones}
- Neutral, because {consequence that weighs neither way}

### Confirmation

{How compliance is checked: a job in `.github/workflows/validate.yml`, a test, a Make target, a manual drill or a review rule.}

## Pros and cons of the options

### {Option 1}

{Optional: a short description, an example or a link.}

- Good, because {argument}
- Neutral, because {argument}
- Bad, because {argument}

### {Option 2}

- Good, because {argument}
- Bad, because {argument}

### {Option 3}

- Good, because {argument}
- Bad, because {argument}

## More information

Upstream sources, checked on {YYYY-MM-DD}:

- {Title}: {URL as an autolink in angle brackets}

Related pages and decisions:

- {Relative link to a docs page, for example to the GitOps architecture page}
- {Relative link to a related ADR}

{Optional: when the decision should be revisited, and what would trigger that.}
