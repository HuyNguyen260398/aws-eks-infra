# Repository Metadata Design

## Purpose

Add the three root-level files needed to explain, license, and safely work with the `aws-eks-infra` repository: `README.md`, `LICENSE.md`, and `.gitignore`. The files must reflect the approved EKS Fargate platform design without implying that the planned infrastructure has already been implemented or deployed.

## README

The README will use a concise, operator-first structure:

- Project purpose and current implementation status.
- Target architecture and principal technology stack.
- Planned repository layout and ownership boundaries.
- Prerequisites for future implementation and deployment.
- Start-from-scratch implementation sequence linking to the committed design and plan.
- Planned quality gates and security cautions.

It will not duplicate the full implementation plan, include application deployment instructions, claim that CI or AWS resources already exist, or add contribution, changelog, or license sections. A GitHub admonition will clearly state that the repository currently contains the approved design and plan only.

## License

`LICENSE.md` will contain the unmodified Apache License 2.0 terms and identify `Copyright 2026 Huy Nguyen` as the project copyright notice. No additional restrictions or incompatible terms will be added.

## Ignore Rules

`.gitignore` will protect Terraform state, state lockfiles, saved plans, crash logs, local backend and variable files, Terraform CLI configuration, credentials, editor metadata, operating-system files, and temporary files. Terraform dependency lock files and committed example configuration files will remain trackable.

## Publication

Only the three requested root files will be included in the implementation commit. After static verification, the commit will use a Conventional Commit message and the current `main` branch will be pushed to `origin/main`, as explicitly requested. No infrastructure apply, GitHub pull request, or repository-setting mutation is in scope.

## Acceptance Criteria

- All three requested files exist at the repository root.
- The README accurately distinguishes planned architecture from implemented state.
- The license text is Apache-2.0 and includes the approved copyright notice.
- Ignore rules cover sensitive and generated Terraform artifacts without ignoring `.terraform.lock.hcl` or example files.
- Markdown structure and whitespace checks pass.
- The implementation commit contains only `README.md`, `LICENSE.md`, and `.gitignore`.
