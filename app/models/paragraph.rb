# encoding: UTF-8
#
# == Schema Information
#
# Table name: paragraphs
#
#  id           :integer(4)      not null, primary key
#  news_id      :integer(4)      not null
#  position     :integer(4)
#  second_part  :boolean(1)
#  locked_by_id :integer(4)
#  body         :text
#  wiki_body    :text
#

# A paragraph is a block of text from a news, with wiki syntax.
# The paragraph never modifies the body (or wiki_body) of a news,
# only the news known its state and when to do the synchronization!
#
# A paragraph can be split in several if it has a blank line in its body.
#
class Paragraph < ActiveRecord::Base
  belongs_to :news

  attr_accessor :user, :after, :already_split

  scope :in_first_part,  where(:second_part => false).order("position ASC")
  scope :in_second_part, where(:second_part => true ).order("position ASC")

### Automatically split paragraphs ###

  # Split body in paragraphs, but preserve code!
  def split_body
    return [] if wiki_body.blank?

    parts   = []
    codemap = {}
    str = wiki_body.gsub(/^``` ?(.+?)\r?\n(.+?)\r?\n```\r?$/m) do
      id = Digest::SHA1.hexdigest($2)
      codemap[id] = $&.chomp
      id + "\n"
    end

    until str.empty?
      left, sep, str = str.partition(/(\r?\n){2}/)
      left.sub!(/\A(\r?\n)+/, '')
      codemap.each { |id,code| left.gsub!(id, code) }
      parts << left + sep
    end

    parts
  end

  before_validation :split_on_create, :on => :create
  def split_on_create
    return if already_split
    sentences = split_body
    self.wiki_body = sentences.pop
    sentences.each do |body|
      news.paragraphs.create :wiki_body     => body,
                             :second_part   => second_part,
                             :already_split => true
    end
  end

  before_validation :split_on_update, :on => :update
  def split_on_update
    sentences = split_body
    self.wiki_body = sentences.shift
    sentences.reverse.each_with_index do |body,i|
      news.paragraphs.create :wiki_body     => body,
                             :second_part   => second_part,
                             :already_split => true,
                             :user          => user,
                             :after         => self.id,
                             :position      => position + 1
    end
  end

### Behaviour ###

  def update_by(user)
    news.editor = user.account
    if wiki_body.blank?
      destroy
    else
      self.user = user
      self.locked_by_id = nil
      save
    end
    news.body_will_change!
    news.save
  end

### Wikify ###

  before_save :wikify_body
  def wikify_body
    self.body = wikify(wiki_body)
  end

  sanitize_attr :body

### Chat ###

  after_create :announce_create
  def announce_create
    Push.create(news, :id => self.id, :after => after, :kind => :add_paragraph)
  end

  after_update :announce_update
  def announce_update
    Push.create(news, :id => self.id, :after => after, :kind => :update_paragraph)
  end

  before_destroy :announce_destroy
  def announce_destroy
    Push.create(news, :id => self.id, :kind => :remove_paragraph)
  end

  # Warning, acts_as_list also declares a before_destroy callback,
  # and this callback must be called after +announce_destroy+.
  # So do NOT move this line upper in this file.
  acts_as_list :scope => :news

  def lock_by(user)
    return true  if locked_by_id == user.id
    return false if locked?
    self.locked_by_id = user.id
    save
    Push.create(news, :id => self.id, :username => user.name, :kind => :lock_paragraph)
    true
  end

  def locked?
    !!locked_by_id
  end

### Presentation ###

  def part
    second_part ? 'second_part' : 'first_part'
  end
end
