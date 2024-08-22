use anyhow::*;
use tree_sitter::Parser; // {Reslt, Context, Error};

fn main() -> Result<()> {
    let mut parser = Parser::new();
    parser
        .set_language(&tree_sitter_typescript::language_tsx())
        .expect("Error loading typescript grammar");

    let contents = {
        let path = std::env::args().skip(1).next().context("no args")?;
        std::fs::read_to_string(&path)?
    };

    let issues = extract_issues(&contents);

    dbg!(issues);

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
    line_beg: u32,
    line_end: u32,
}

#[derive(Debug)]
struct IssueList<'a> {
    txt_buf: Vec<u8>,
    issues: Vec<Issue<'a>>,
}

fn extract_issues<'a>(input: &'a str) -> IssueList {
    #[derive(Debug)]
    enum Comment<'a> {
        Block { txt: &'a str, line: u32 },
        Basic { txt: &'a str, line: u32 },
    }

    let mut comments = Vec::with_capacity(input.len() / 80);

    enum State {
        None,
        Comment_Basic { start: usize, line: u32 },
        Comment_Block { start: usize, line: u32 },
    }

    let mut state: State = State::None;
    let mut char_iter = input.as_bytes().into_iter().enumerate();

    let mut cur_line = 0;

    while let Some((i, char)) = char_iter.next() {
        match state {
            State::None => match char {
                b'/' => match char_iter.next() {
                    Some((_, b'/')) => {
                        state = State::Comment_Basic {
                            start: i,
                            line: cur_line,
                        }
                    }
                    Some((_, b'*')) => {
                        state = State::Comment_Block {
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
            State::Comment_Basic { start, line } => {
                if *char == b'\n' {
                    comments.push(Comment::Basic {
                        txt: &input[start..=i - 1].trim_ascii().trim_start_matches("//"),
                        line,
                    });
                    state = State::None;
                    cur_line += 1;
                }
            }
            State::Comment_Block { start, line } => {
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

        let label = &txt.trim_ascii_start().trim_start_matches("//").trim_start_matches('*').as_bytes()[0..=MAX_LEN].to_ascii_uppercase();

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

            let mut sub_i = i + 1;
            let mut prev_line = *line;

            let line_beg = *line;
            let mut line_end = *line;

            if sub_i < comments.len() {
                let subsequent = comments[sub_i..].into_iter().map_while(|c| match c {
                    &Comment::Basic { txt, line } if line == prev_line + 1 => Some((txt, line)),
                    _ => None,
                });

                for (subsequent_comment, subsequent_line) in subsequent {
                    if let Some(_) = identify_type(subsequent_comment) {
                        break;
                    }
                    issues_txt_buf.push(b'\n');
                    issues_txt_buf.extend_from_slice(txt.trim_ascii_start().trim_start_matches("//").as_bytes());
                    txt_len += txt.len();
                    _ = comments_iter.next();
                    line_end = subsequent_line;
                }
            }
            issues.push(Issue {
                txt: unsafe {
                    let slice = std::slice::from_raw_parts(&issues_txt_buf[txt_start], txt_len);
                    let str = std::str::from_utf8_unchecked(slice);
                    str.trim_ascii_end()
                },
                kind,
                line_beg,
                line_end,
            });
        } else if let Comment::Block { line, txt } = comment {
            let Some(kind) = identify_type(txt) else {
                continue;
            };

            let txt_start = {issues_txt_buf.len() + 1};
            let txt_len = txt.len();
            issues_txt_buf.extend_from_slice(txt.as_bytes());

            let txt = unsafe {
                    let slice = std::slice::from_raw_parts(&issues_txt_buf[txt_start], txt_len);
                    let str = std::str::from_utf8_unchecked(slice);
                    str.trim_ascii_end()
                };
            let line_count = txt.as_bytes().into_iter().filter(|&&c| c == b'\n').count();
            issues.push(Issue {
                txt,
                kind,
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
