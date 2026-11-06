//! Runtime configuration (mirrors config.json).

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AntiCrawler {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub redirect_url: String,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub zwsm: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub anti_crawler: AntiCrawler,
}

impl Config {
    pub fn load(path: &str) -> Result<Self, String> {
        let data = std::fs::read(path).map_err(|e| format!("read config {path}: {e}"))?;
        let mut c: Config =
            serde_json::from_slice(&data).map_err(|e| format!("parse config {path}: {e}"))?;
        if c.port == 0 {
            c.port = 18921;
        }
        Ok(c)
    }
}
