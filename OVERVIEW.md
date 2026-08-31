# Application Template

## What it is

The starting point for building a new containerised application in this family
— not an application itself. There is nothing here to run and nothing to see;
it is the skeleton you copy when you want to add something new.

Its value is that everything except your program is already decided and already
working: how the container is built, how it is published, how it behaves on a
cluster as opposed to a laptop, and — for anything with a browser interface —
how a user reaches it privately and securely. You supply the program. The rest
comes with the template.

*This document is for people building an app. Every other app in the family has
one written for the people who use it.*

## Use cases

- Adding a new tool to the family, in any language: a command-line program, a
  notebook-based tutorial, a graphical application, a licensed vendor tool.
- Making an existing piece of research software runnable by other people
  without them having to install it.
- Giving a workshop or course its own purpose-built environment.

## What's included

- A build that produces both container formats at once — one for ordinary
  machines, one for research clusters — and publishes them together with
  matching version numbers, so the two can never drift apart.
- A startup arrangement that behaves correctly in both places, including the
  differences that usually only surface once something reaches a cluster and
  fails there.
- Everything a browser-based application needs to be reached safely: a single
  entry point, a secret unique to each session, and the plumbing that keeps an
  interactive session alive.

## Where it can run

Anything built from this template runs on your own computer through Docker and
on a research cluster through Apptainer/Singularity, from the same source.
Applications with a browser interface can additionally be offered through a
science gateway, which starts them and hands users a link.

## Getting started

Copy the template, replace the program with your own, describe what it needs,
and publish. The family's conventions document explains the decisions built
into the template and the small number of rules an application has to follow —
most of which exist because a cluster is not a laptop.

The existing applications are worked examples, and the closest one to what you
are building is usually the fastest thing to read: a batch tool, a notebook
environment, or a graphical desktop.
