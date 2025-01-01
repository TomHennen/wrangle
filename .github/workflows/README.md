# Wrangle Workflows

Wrangle aims to provide _both_:

1. Reusable workflows that other projects can easily call to achieve their goals.
2. Minimal _example_ workflows that other projects can adopt themselves to use Wrangle workflows and actions.

Wrangle also has it's own workflows that it uses to mange itself.
Wrangle's own workflows all have filenames that start with `local_`.

## TODO:

- Provide example workflows.
- Provide reuable workflow for code change...

## build_and_publish_container.yml

This reusable workflow allows callers to easily, build and publish their containers with a minimum of fuss.

It's goal is to follow all best practices for building and publishing container images, including:

1. Publishing SLSA provenance.
2. (TODO) Creating and publishing SBOMs.
3. (TODO) Scanning for vulnerabilities.
4. ...

## check_source_changes.yml

This reusable workflow allows callers to easily scan their source changes.

It creates a summary of all the tool results in the GitHub Action.

![check_source_change_summary](/assets/images/check_source_change_summary.png)