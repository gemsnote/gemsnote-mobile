/// New-note preference only; existing notes always retain their stored format.
enum DefaultEditor {
  html('富文本', false),
  markdown('Markdown', true);

  const DefaultEditor(this.label, this.isMarkdown);
  final String label;
  final bool isMarkdown;
}
