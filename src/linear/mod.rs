use anyhow::{anyhow, Context, Result};

#[cynic::schema("linear")]
pub mod schema {}

const URI: &'static str = "https://api.linear.app/graphql";

pub mod labels {
    use super::*;
    use crate::IssueKind;

    use cynic::{http::SurfExt, QueryBuilder};

    #[derive(cynic::QueryFragment, Debug)]
    #[cynic(graphql_type = "Query")]
    pub struct ListIssuesQuery {
        pub issue_labels: IssueLabelConnection,
    }

    #[derive(cynic::QueryFragment, Debug)]
    pub struct IssueLabelConnection {
        pub nodes: Vec<IssueLabel>,
    }

    #[derive(cynic::QueryFragment, Debug, Clone)]
    pub struct IssueLabel {
        pub id: cynic::Id,
        pub name: String,
    }

    #[derive(Debug)]
    pub struct Label {
        kind: IssueKind,
        label_id: cynic::Id,
    }

    pub async fn get(
        config: crate::config::Config,
    ) -> Result<[Label; IssueKind::ISSUE_KIND_COUNT]> {
        let result = surf::post(URI)
            .header("Authorization", config.profile.api_key)
            .run_graphql(ListIssuesQuery::build(()))
            .await
            .map_err(|e| anyhow!(e))
            .context("failed to fetch issues")?;

        if let Some(errors) = result.errors {
            anyhow::bail!("Errors fetching labels: {:?}", errors);
        }

        let Some(linear_labels) = result.data.map(|d| d.issue_labels.nodes) else {
            unreachable!("checked errors but still no label data");
        };

        let mut labels = IssueKind::ALL_ISSUES.map(|name| (name, Option::<Label>::None));

        for &mut (issue_kind, ref mut label) in labels.iter_mut() {
            let name = config.label_names.label_rename_for(issue_kind);

            *label = linear_labels
                .iter()
                .find(|label| label.name == name)
                .map(|label| Label {
                    kind: issue_kind,
                    label_id: label.id.to_owned(),
                });
        }

        // TODO: make missing issues

        return labels.try_map(|(kind, label)| label.ok_or(anyhow!("Missing label {:?}", kind)));
    }
}

pub mod issues {
    use std::str::FromStr;

    use super::*;
    use cynic::{http::SurfExt, MutationBuilder, QueryBuilder};

    pub struct IssueIdentifier {
        prefix: String,
        num: u32,
    }

    impl FromStr for IssueIdentifier {
        type Err = anyhow::Error;

        fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
            let (prefix, num) = s
                .split_once("-")
                .with_context(|| format!("no - in identifier {}", s))?;
            let num = num.parse::<u32>().context("invalid issue number")?;

            return Ok(IssueIdentifier {
                prefix: prefix.to_owned(),
                num,
            });
        }
    }

    #[derive(Clone)]
    pub struct NewIssue {
        label_id: String,
        description: String,
        title: Option<String>,
        team_id: String,
    }

    pub async fn create<'a>(
        config: crate::config::Config,
        issues: &'a [NewIssue],
    ) -> Vec<Result<IssueIdentifier>> {
        #[derive(cynic::QueryVariables, Debug)]
        struct IssueCreateVariables<'a> {
            pub team_id: &'a str,
            pub description: Option<&'a str>,
            pub label_ids: Option<Vec<&'a str>>,
            pub project_id: Option<&'a str>,
            pub title: Option<&'a str>,
        }

        #[derive(cynic::QueryFragment, Debug)]
        #[cynic(graphql_type = "Mutation", variables = "IssueCreateVariables")]
        struct IssueCreate {
            #[arguments(input: { teamId: $team_id, description: $description, labelIds: $label_ids, projectId: $project_id, title: $title })]
            pub issue_create: IssuePayload,
        }

        #[derive(cynic::QueryFragment, Debug)]
        struct IssuePayload {
            pub success: bool,
            pub issue: Option<Issue>,
        }

        #[derive(cynic::QueryFragment, Debug)]
        struct Issue {
            pub identifier: String,
        }

        let request_futures = issues.into_iter().map(|issue| {
            let issue = issue.clone(); //Arc::new(issue.clone());
            let api_key = config.profile.api_key.clone();

            tokio::spawn(async move {
                let op = IssueCreate::build(IssueCreateVariables {
                    description: Some(&issue.description),
                    title: issue.title.as_deref(),
                    label_ids: Some(vec![&issue.label_id]),
                    project_id: None,
                    team_id: &issue.team_id,
                });
                surf::post(URI)
                    .header("Authorization", api_key)
                    .run_graphql(op)
                    .await
                    .map_err(|e| anyhow!(e))
                    .context("failed to create issue")
            })
        });

        let responses = futures::future::join_all(request_futures).await;

        let results = responses
            .into_iter()
            .flatten()
            .map(|res| {
                res.and_then(|response| {
                    response
                        .data
                        .expect("ok response has data")
                        .issue_create
                        .issue
                        .context("failed to create issue")
                        .map(|issue| {
                            issue
                                .identifier
                                .parse::<IssueIdentifier>()
                                .expect("issue identifier")
                        })
                })
            })
            .collect();

        return results;
    }
}
