use anyhow::*;

fn main() -> Result<()> {
    let path = std::env::args().skip(1).next().context("no args")?;
    let contents = std::fs::read_to_string(&path)?;
    let issues = extract_issues(&contents, &path);

    dbg!(&issues.issues);
    dbg!(&issues.issues.len());

    Ok(())
}

#[derive(Debug)]
enum IssueKind {
    FIXME,
    TODO,
}

#[derive(Debug)]
struct Issue<'a> {
    kind: IssueKind,
    txt: &'a str,
    file_name: &'a str,
    line_beg: u32,
    line_end: u32,
}

#[derive(Debug)]
struct IssueList<'a> {
    txt_buf: Vec<u8>,
    issues: Vec<Issue<'a>>,
}

fn extract_issues<'a>(input: &'a str, file_name: &'a str) -> IssueList<'a> {
    #[derive(Debug)]
    enum Comment<'a> {
        Block { txt: &'a str, line: u32 },
        Basic { txt: &'a str, line: u32 },
    }

    let comments_init_cap = input.len() / 80;
    let mut comments = Vec::with_capacity(comments_init_cap);

    enum State {
        None,
        Basic { start: usize, line: u32 },
        Block { start: usize, line: u32 },
    }

    let mut state: State = State::None;
    let mut char_iter = input.as_bytes().into_iter().enumerate();

    let mut cur_line = 0;

    while let Some((i, char)) = char_iter.next() {
        match state {
            State::None => match char {
                b'/' => match char_iter.next() {
                    Some((_, b'/')) => {
                        state = State::Basic {
                            start: i,
                            line: cur_line,
                        }
                    }
                    Some((_, b'*')) => {
                        state = State::Block {
                            start: i,
                            line: cur_line,
                        }
                    }
                    Some((_, b'\n')) => cur_line += 1,
                    _ => continue,
                },
                b'\n' => cur_line += 1,
                _ => continue,
            },
            State::Basic { start, line } => {
                if *char == b'\n' {
                    comments.push(Comment::Basic {
                        txt: &input[start..=i - 1].trim_ascii().trim_start_matches("//"),
                        line,
                    });
                    state = State::None;
                    cur_line += 1;
                }
            }
            State::Block { start, line } => {
                if *char == b'*' {
                    let next = char_iter.next();
                    if let Some((_, b'/')) = next {
                        comments.push(Comment::Block {
                            txt: &input[start..=i + 1]
                                .trim_ascii()
                                .trim_start_matches("/*")
                                .trim_end_matches("*/"),
                            line,
                        });
                        state = State::None;
                    } else if let Some((_, b'\n')) = next {
                        cur_line += 1;
                    }
                }
                if *char == b'\n' {
                    cur_line += 1;
                }
            }
        }
    }

    let mut issues_txt_buf = Vec::<u8>::with_capacity(comments.len() * 20);
    let mut issues = Vec::<Issue<'a>>::with_capacity(comments.len());

    fn identify_type(txt: &str) -> Option<IssueKind> {
        const MAX_LEN: usize = 6;

        if txt.len() < MAX_LEN {
            return None;
        }

        let label = &txt
            .trim_ascii_start()
            .trim_start_matches("//")
            .trim_start_matches('*')
            .as_bytes()[0..=MAX_LEN]
            .to_ascii_uppercase();

        if label.starts_with(b"FIXME") {
            return Some(IssueKind::FIXME);
        }
        if label.starts_with(b"TODO") {
            return Some(IssueKind::TODO);
        }

        return None;
    }

    let mut comments_iter = comments.iter().enumerate();

    while let Some((i, comment)) = comments_iter.next() {
        if let Comment::Basic { line, txt } = comment {
            let Some(kind) = identify_type(txt) else {
                continue;
            };

            let txt_start = { issues_txt_buf.len() + 1 };
            let mut txt_len = txt.len();
            issues_txt_buf.extend_from_slice(txt.as_bytes());

            let line_beg = *line;
            let mut line_end = *line;

            let sub_i = i + 1;
            let mut prev_line = *line;

            for subsequent_comment_i in sub_i..comments.len() {
                let Comment::Basic {
                    txt: subsequent_txt,
                    line: subsequent_line,
                } = comments[subsequent_comment_i]
                else {
                    break;
                };
                if subsequent_line != prev_line + 1 {
                    break;
                }
                if let Some(_) = identify_type(subsequent_txt) {
                    break;
                }

                issues_txt_buf.push(b'\n');
                issues_txt_buf.extend_from_slice(
                    subsequent_txt
                        .trim_ascii_start()
                        .trim_start_matches("//")
                        .as_bytes(),
                );
                txt_len += subsequent_txt.len();

                _ = comments_iter.next();

                line_end = subsequent_line;
                prev_line = subsequent_line;
            }

            txt_len = issues_txt_buf[txt_start..].trim_ascii_end().len();

            issues.push(Issue {
                txt: unsafe {
                    let slice = std::slice::from_raw_parts(&issues_txt_buf[txt_start], txt_len);
                    std::str::from_utf8_unchecked(slice)
                },
                file_name,
                kind,
                line_beg,
                line_end,
            });
        } else if let Comment::Block { line, txt } = comment {
            let Some(kind) = identify_type(txt) else {
                continue;
            };

            let txt_start = { issues_txt_buf.len() + 1 };
            let txt_len = txt.trim_ascii_end().len();
            issues_txt_buf.extend_from_slice(txt.as_bytes());

            let txt = unsafe {
                let slice = std::slice::from_raw_parts(&issues_txt_buf[txt_start], txt_len);
                std::str::from_utf8_unchecked(slice)
            };
            let line_count = txt.as_bytes().into_iter().filter(|&&c| c == b'\n').count();
            issues.push(Issue {
                txt,
                kind,
                file_name,
                line_beg: *line,
                line_end: *line + line_count as u32,
            });
        }
    }

    return IssueList {
        txt_buf: issues_txt_buf,
        issues,
    };
}
