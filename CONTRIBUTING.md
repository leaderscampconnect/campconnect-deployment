# Contributing to CampConnect

This project is split across several microservice repositories. Use the same
Git workflow in every repository so the team history remains easy to review
and demonstrate.

## Branch Workflow

1. Pull the latest `main` branch.
2. Create a focused branch such as `feat/event-waitlist` or
   `fix/gateway-role-check`.
3. Commit each complete, testable change separately.
4. Push the branch and open a pull request.
5. Merge only after the relevant tests and documentation checks pass.

Do not commit directly to another member's feature branch or rewrite shared
history.

## Commit Messages

Use the following format:

```text
<type>: <short imperative description>
```

Accepted types:

- `feat`: add or change application behavior
- `fix`: correct a defect
- `test`: add or improve automated tests
- `docs`: update project documentation
- `refactor`: restructure code without changing behavior
- `build`: change dependencies, containers, or build configuration
- `ci`: change continuous integration configuration
- `chore`: perform necessary repository maintenance

Examples:

```text
feat: add event waitlist promotion
fix: reject notification access without user role
test: cover organizer event permissions
docs: document Config Server environment variables
```

Avoid messages such as `update`, `changes`, `work`, or `final version`.

## Commit Scope

A meaningful commit should:

- represent one coherent change
- include its related tests when practical
- update documentation when behavior or configuration changes
- keep generated files, IDE metadata, credentials, and local `.env` files out
  of Git
- leave the repository buildable and testable

Do not create empty commits only to increase the commit count. Commit
regularly as complete units of work become ready.

## Pull Request Checklist

- The branch is current with `main`.
- The change has a clear title and description.
- Automated tests pass.
- Docker or Compose configuration renders successfully when changed.
- API behavior, environment variables, and demonstration steps are documented.
- No credentials or personal configuration files are included.
