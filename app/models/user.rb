class User < ActiveRecord::Base
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable and :omniauthable
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable, :validatable

  has_many :feedbacks

  def active_for_authentication?
    super && is_approved?
  end

  def inactive_message
    if !is_approved?
      :not_approved
    else
      super # Use whatever other message
    end
  end
end
