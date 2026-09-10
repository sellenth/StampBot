# Deployment

Production runs on **Railway** and serves **https://stamp-bot.com**. The app is
built from the repository's `Dockerfile`. The startup script in that image runs
release migrations before starting Phoenix.

## Select production

Open the [StampBot production service](https://railway.com/project/66b82311-076d-44bb-bb29-8429380561e8/service/c54e6145-330e-4e68-9961-295a1fbe471f?environmentId=a498e40a-7d9f-491a-af9e-a85fd27c973d).
Verify the environment, service, and `stamp-bot.com` custom domain before
changing variables or deploying. Do not infer the target from an old local CLI
link.

| Target | Railway ID |
| --- | --- |
| Project | `66b82311-076d-44bb-bb29-8429380561e8` |
| App service | `c54e6145-330e-4e68-9961-295a1fbe471f` |
| Production environment | `a498e40a-7d9f-491a-af9e-a85fd27c973d` |

Production automatically deploys `main` from
[`sellenth/StampBot`](https://github.com/sellenth/StampBot). This was
verified on September 9, 2026: GitHub's `stampbot - StampBot` commit status linked
commit `a8839e8` to a successful Railway deployment. Check **Settings → Source**
if the repository or deployment branch changes.

## Deploy a reviewed commit

1. Run the relevant checks described in the [README](../README.md).
2. Review the diff, commit the intended files, and push the reviewed commit to
   GitHub `main`. This starts the production deployment.
3. If a manual deployment is needed, open Railway's command palette (`Cmd+K`)
   and choose **Deploy Latest Commit** for the app service.
4. Verify that the deployment details show the intended Git commit and that the
   build, migrations, and application startup succeed. Confirm
   `https://stamp-bot.com` responds and check a submission's saved progress.

Check the GitHub status for the exact commit being deployed:

```sh
gh api "repos/sellenth/StampBot/commits/$(git rev-parse HEAD)/status" \
  --jq '.statuses[] | select(.context == "stampbot - StampBot") | {state, target_url, description}'
```

The **Redeploy** action and `railway redeploy` reuse the existing deployment's
code. They do not deploy a newly pushed commit. See Railway's
[deployment actions](https://docs.railway.com/deployments/deployment-actions).

The obsolete deployment scripts have been removed. Commit and push explicitly;
there is no script that stages all local files or deploys multiple environments.

## Variables and database access

Manage production values in the selected app service's **Variables** tab. Keep
`PHX_HOST=stamp-bot.com`, and preserve the deployed `DATABASE_URL`,
`SECRET_KEY_BASE`, provider keys, and processing limits. See the
[security and rollout settings](milestone-two.md) for proxy configuration and
limits. Railway routes requests to the application's configured `PORT`.

For database administration, use the database service's connection details in
the same Railway project and environment. For local development, use the local
PostgreSQL database configured in `config/dev.exs`; `dev.sh` does not open a
production database proxy.

## Source uploads

Use the GitHub source flow above for production. `railway up` uploads files from
the local directory and applies its own ignore rules; `.dockerignore` controls
the Docker build context and should not be treated as a Railway upload filter.
This checkout contains historical database backups and may contain local
credentials or private review exports. Do not upload the entire working tree.
See Railway's [CLI deployment documentation](https://docs.railway.com/cli/deploying).
