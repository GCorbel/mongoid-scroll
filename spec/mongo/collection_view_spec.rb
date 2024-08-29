require 'spec_helper'

if Object.const_defined?(:Mongo)
  describe Mongo::Collection::View do
    [Mongoid::Scroll::Cursor, Mongoid::Scroll::Base64EncodedCursor].each do |cursor_type|
      context cursor_type do
        context 'scrollable' do
          subject do
            Mongoid.default_client['feed_items'].find
          end
          it ':scroll' do
            expect(subject).to respond_to(:scroll)
          end
        end
        context 'with multiple sort fields' do
          subject do
            Mongoid.default_client['feed_items'].find.sort(name: 1, value: -1)
          end
          it 'raises Mongoid::Scroll::Errors::MultipleSortFieldsError' do
            expect { subject.scroll(cursor_type) }.to raise_error Mongoid::Scroll::Errors::MultipleSortFieldsError,
                                                                  /You're attempting to scroll over data with a sort order that includes multiple fields: name, value./
          end
        end
        context 'with different sort fields between the cursor and the criteria' do
          subject do
            Mongoid.default_client['feed_items'].find.sort(name: -1)
          end

          it 'raises Mongoid::Scroll::Errors::MismatchedSortFieldsError' do
            record = Feed::Item.create!
            cursor = cursor_type.from_record(record, field: record.fields['a_string'])
            expect(cursor).to be_a cursor_type
            error_string = /You're attempting to scroll over data with a sort order that differs between the cursor and the original criteria: field_name, direction./
            expect { subject.scroll(cursor, field_type: String) }.to raise_error Mongoid::Scroll::Errors::MismatchedSortFieldsError, error_string
          end
        end
        context 'with no sort' do
          subject do
            Mongoid.default_client['feed_items'].find
          end
          it 'adds a default sort by _id' do
            expect(subject.scroll(cursor_type).sort).to eq('_id' => 1)
          end
        end
        context 'with data' do
          before :each do
            10.times do |i|
              Mongoid.default_client['feed_items'].insert_one(
                a_string: i.to_s,
                a_integer: i,
                a_datetime: DateTime.mongoize(DateTime.new(2013, i + 1, 21, 1, 42, 3, 'UTC')),
                a_date: Date.mongoize(Date.new(2013, i + 1, 21)),
                a_time: Time.mongoize(Time.at(Time.now.to_i + i))
              )
            end
          end
          context 'default' do
            it 'scrolls all' do
              records = []
              Mongoid.default_client['feed_items'].find.scroll(cursor_type) do |record, iterator|
                records << record
              end
              expect(records.size).to eq 10
              expect(records).to eq Mongoid.default_client['feed_items'].find.to_a
            end
          end
          { a_string: String, a_integer: Integer, a_date: Date, a_datetime: DateTime }.each_pair do |field_name, field_type|
            context field_type do
              it 'scrolls all with a block' do
                records = []
                Mongoid.default_client['feed_items'].find.sort(field_name => 1).scroll(cursor_type, field_type: field_type) do |record, iterator|
                  records << record
                end
                expect(records.size).to eq 10
                expect(records).to eq Mongoid.default_client['feed_items'].find.to_a
              end
              it 'scrolls all with a break' do
                records = []
                cursor = nil
                Mongoid.default_client['feed_items'].find.sort(field_name => 1).limit(5).scroll(cursor_type, field_type: field_type) do |record, iterator|
                  records << record
                  cursor = iterator.next_cursor
                  expect(cursor).to be_a cursor_type
                end
                expect(records.size).to eq 5
                Mongoid.default_client['feed_items'].find.sort(field_name => 1).scroll(cursor, field_type: field_type) do |record, iterator|
                  records << record
                  cursor = iterator.next_cursor
                  expect(cursor).to be_a cursor_type
                end
                expect(records.size).to eq 10
                expect(records).to eq Mongoid.default_client['feed_items'].find.to_a
              end
              it 'scrolls in descending order' do
                records = []
                Mongoid.default_client['feed_items'].find.sort(field_name => -1).limit(3).scroll(cursor_type, field_type: field_type, field_name: field_name) do |record, iterator|
                  records << record
                end
                expect(records.size).to eq 3
                expect(records).to eq Mongoid.default_client['feed_items'].find.sort(field_name => -1).limit(3).to_a
              end
              it 'map' do
                record = Mongoid.default_client['feed_items'].find.limit(3).scroll(cursor_type, field_type: field_type, field_name: field_name).map { |r| r }.last
                cursor = cursor_type.from_record(record, field_type: field_type, field_name: field_name)
                expect(cursor).to_not be nil
                expect(cursor.value).to eq record[field_name.to_s]
                expect(cursor.tiebreak_id).to eq record['_id']
              end
              it 'can scroll back with the previous cursor' do
                first_iterator = nil
                second_iterator = nil
                third_iterator = nil

                Mongoid.default_client['feed_items'].find.sort(field_name => 1).limit(2).scroll(cursor_type, field_type: field_type) do |_, iterator|
                  first_iterator = iterator
                end

                Mongoid.default_client['feed_items'].find.sort(field_name => 1).limit(2).scroll(first_iterator.next_cursor, field_type: field_type) do |_, iterator|
                  second_iterator = iterator
                end

                Mongoid.default_client['feed_items'].find.sort(field_name => 1).limit(2).scroll(second_iterator.next_cursor, field_type: field_type) do |_, iterator|
                  third_iterator = iterator
                end

                records = Mongoid.default_client['feed_items'].find.sort(field_name => 1)
                expect(Mongoid.default_client['feed_items'].find.sort(field_name => 1).limit(2).scroll(second_iterator.previous_cursor, field_type: field_type).to_a).to eq(records.limit(2).to_a)
                expect(Mongoid.default_client['feed_items'].find.sort(field_name => 1).limit(2).scroll(third_iterator.previous_cursor, field_type: field_type).to_a).to eq(records.skip(2).limit(2).to_a)
              end
            end
          end
        end
        context 'with overlapping data', if: MongoDB.mmapv1? do
          before :each do
            3.times { Feed::Item.create! a_integer: 5 }
            Feed::Item.first.update_attributes!(name: Array(1000).join('a'))
          end
          it 'natural order is different from order by id' do
            # natural order isn't necessarily going to be the same as _id order
            # if a document is updated and grows in size, it may need to be relocated and
            # thus cause the natural order to change
            expect(Feed::Item.order_by('$natural' => 1).to_a).to_not eq Feed::Item.order_by(_id: 1).to_a
          end
          [{ a_integer: 1 }, { a_integer: -1 }].each do |sort_order|
            it "scrolls by #{sort_order}" do
              records = []
              cursor = nil
              Mongoid.default_client['feed_items'].find.sort(sort_order).limit(2).scroll(cursor_type) do |record, iterator|
                records << record
                cursor = iterator.next_cursor
              end
              expect(records.size).to eq 2
              Mongoid.default_client['feed_items'].find.sort(sort_order).scroll(cursor) do |record, iterator|
                records << record
              end
              expect(records.size).to eq 3
              expect(records).to eq Mongoid.default_client['feed_items'].find.sort(sort_order.merge(_id: sort_order[:a_integer])).to_a
            end
          end
        end
      end
    end
  end
end
