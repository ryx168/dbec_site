# diamondbarevergreen.com

Static site source for diamondbarevergreen.com, pulled from the old origin
(`dbec` account on 209.188.7.230 / server1.supere.tech, which is being
decommissioned) on 2026-10-03. Plain static HTML/CSS/JS (Mobirise-built) -
no build step, no backend, no database.

## Editing

Edit the HTML/CSS/image files directly in this repo (via the GitHub web
editor, a local clone, or any git client) and push to `main`.

## Deploying

The live site is served by Cloudflare Pages, project `diamondbarevergreen-com`.
Once this repo is connected to that project (Cloudflare dashboard ->
Workers & Pages -> diamondbarevergreen-com -> Settings -> Builds &
deployments -> Connect to Git), every push to `main` deploys automatically -
build command: none, build output directory: `/`.

Until that one-time connection is made, deploys are manual: download this
repo as a zip and upload it via "Create deployment" in the same dashboard
screen.

## What's NOT in this repo

`last_ver/` (an older snapshot of the same pages) and `very_old/` (284MB of
legacy pre-migration content) were left on the origin server and not copied
here, since they're not part of the live site. Grab them from the origin
before it's decommissioned if they're still needed for reference.
