use anyhow::{Result, Context};

#[derive(serde::Deserialize, Debug)]
pub struct ConfigFile {
    pub profiles: Vec<Profile>,
    #[serde(default = "label_names_default")]
    pub label_names: LabelNames,
}

#[derive(Debug)]
pub struct Config {
    pub profile: Profile,
    pub label_names: LabelNames,
}


#[derive(serde::Deserialize, Debug, Default)]
pub struct LabelNames {
    #[serde(default = "label_name_fixme_default")]
    FIXME: String,
    #[serde(default = "label_name_todo_default")]
    TODO: String,
}

impl LabelNames {
    pub fn label_rename_for<'a>(&'a self, issueKind: crate::IssueKind) -> &'a str {
        use crate::IssueKind;
        match issueKind {
            IssueKind::FIXME => &self.FIXME,
            IssueKind::TODO => &self.TODO,
        }
    }
}

pub fn load() -> Result<Config> {
    let config_txt = std::fs::read_to_string("./fixme.toml").context("Failed to read config file")?;
    let mut config_file = toml::from_str::<ConfigFile>(&config_txt).context("Failed to parse config file")?;
    return Ok(Config {
        profile: config_file.profiles.pop().context("No profiles in config file")?,
        label_names: config_file.label_names,
    });
}


fn default_profile_default() -> Option<Profile> {
    return None;
}

fn label_names_default() -> LabelNames {
    LabelNames {
        FIXME: label_name_fixme_default(),
        TODO: label_name_todo_default(),
    }
}

fn label_name_fixme_default() -> String {
    "FIXME".to_string()
}

fn label_name_todo_default() -> String {
    "TODO".to_string()
}

#[derive(serde::Deserialize, Debug)]
pub struct Profile {
    pub name: String,
    pub api_key: String,
}

