def replace_code_in_file(file_path, old_string, new_string):
    try:
        # Open the file for reading and writing
        with open(file_path, 'r') as file:
            content = file.read()

        # Replace the old string with the new string
        content = content.replace(old_string, new_string)

        # Write the modified content back to the file
        with open(file_path, 'w') as file:
            file.write(content)
        print(f"Successfully replaced code.")
        
    except FileNotFoundError:
        print(f"The file {file_path} was not found.")
    except Exception as e:
        print(f"An error occurred: {e}")
