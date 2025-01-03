# Wrangle Source

This folder contains all the tools and actions for dealing with source.

For now it just includes source scanning integrations.

## User instructions

Users can use Wrangle Source in multiple ways:

1. (GitHub only) By using Wrangle's reusable source workflow, [example](/gh_workflow_examples/check_source_change.yml).
2. (GitHub only) By calling Wrangle's [source/actions/scan](/source/actions/scan) GitHub action directly.
3. By having Wrangle run the containerized tools directly, e.g. `./source/tools/run.sh -r ghcr.io/tomhennen/wrangle osv zizmor`

## Actions

Wrangle Source Actions are [GitHub Actions](https://github.com/features/actions) that process source code and emit results.

### Aggregate action

Wrangle Source provides a single, aggregate, [scan](/source/actions/scan/action.yml) which runs all of
the individual Wrangle Source Actions, and all the Wrangle Source Tools.

### Individual actions

Individual actions are GitHub actions that perform one type of analysis over a repo's source code and output the results.

#### Existing individual actions

* [scorecard](/source/actions/scorecard/action.yml) - Runs scorecard over the repo's source, recording any issues.

#### Adding a new individual action

1. Create a new folder under [source/actions](/source/actions/) for your tool.
2. Create the action.yml, have it do its analysis and output its results to ./metadata/YOUR_TOOL_NAME/.
3. Update [scan](/source/actions/scan/action.yml) to call your action.

#### Inputs

Individual actions can expect to have the repo's source code checked out to `.`.

#### Outputs

Source actions output their results to the `./metadata/<action name>` folder

* User friendly data to `output.txt` or `output.md`
* Machine readable [SARIF](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html),
  documenting any problems discovered, as `output.sarif`

## Tools

Wrangle Source Tools are container images that analyize source code and
write their results to standard locations.

### Input

Wrangle Source Tools are container images that get run with

* The source mapped readonly to `/src`
* A metadata directory, for the tool, mapped to `/metadata`

### Output

Tools output their results to the `/metadata` folder as

* User friendly data to `output.txt` or `output.md`
* Machine readable [SARIF](https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html),
  documenting any problems discovered, as `output.sarif`

### Existing Tools

* osv - Runs osv over the source code and records any discovered vulnerabilities.
* zizmor - Runs zizmor over the GitHub workflows and records any discovered vulnerabilities.

### Adding a new source tool

1. Create a new folder under [source/tools](/source/tools/) for your tool.
2. Create a Dockerfile that encapsulates your tool, processes the source, and writes outputs.
3. Update [local_build_tools.yml](/.github/workflows/local_build_tools.yml) and add your tool to the `strategy`.
