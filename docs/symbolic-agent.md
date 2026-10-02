# Neuro-Symbolic Agent

The goal of this document is to describe a new type of AI Agent that
is able to use different types of AI Systems together.


Instead of a single LLM model that drives understanding, querying and
generative interactions, the goal is to use a Mosaic of smaller LLMs
and AI tool in order to guide the LLM to the right answer the first
time.


Steps

1. User query or request
2. Query or request is parses by smaller "LLM"
3. Parsed query is run again Prolog Knowledge base
4. Another LLM is uses to review the results of the prolog query
5. Plan ->?


## FSM for coding agents.

1. Gather
1. Review
1. Implement
1. Validate

## Architecture Digram

```plantuml
@startuml






@enduml
```
